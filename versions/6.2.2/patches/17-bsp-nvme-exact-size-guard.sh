# 17-bsp-nvme-exact-size-guard.sh — refuse unsafe data-layout flashes on the wrong NVMe.
#
# NVIDIA normally compares the XML's nominal external-device size only after it has
# run `parted mklabel`, written the primary GPT, and written the secondary GPT image.
# That is too late for a persistent tail partition: if the real disk is larger than
# the XML, the nominal secondary-GPT write lands inside the previously expanded data.
#
# Add an early guard to create_gpt(). It activates only when the external flash index
# contains our partition named "data". Before any GPT write it requires:
#   1. the secondary-GPT end to equal blockdev --getsize64 exactly; and
#   2. if p16 already exists, its start/end geometry to match the generated layout.
# The second check catches an accidental APP_SIZE/layout change before it can orphan the
# existing filesystem. Stock APP-auto-expand layouts have no "data" row and retain
# NVIDIA's normal behavior.
#
# Sourced by apply_patches() with: $LFT $SUDO and log()/die() in scope.

_f="$LFT/tools/kernel_flash/l4t_flash_from_kernel.sh"
[ -f "$_f" ] || die "kernel flash target script not found: $_f"

_marker='# G1_EXACT_NVME_SIZE_GUARD'
if grep -qF "$_marker" "$_f"; then
    log "  exact-NVMe-size guard already installed"
else
	_blk='# G1_EXACT_NVME_SIZE_GUARD
	# A G1 data layout is safe to recreate only on the exact disk geometry used
	# to generate its GPT images. Validate before mklabel or either GPT write.
	local g1_has_data=0
	local g1_expected_bytes=""
	local g1_data_start=""
	local g1_secondary_start=""
	local g1_part g1_type g1_start g1_size g1_disk g1_actual_bytes
	local g1_data_node g1_sys_start g1_current_start g1_current_size g1_current_end
	for item in "${ACTIVE_INDEX_ARRAY[@]}"; do
		g1_part=$(echo "${item}" | cut -d, -f 2 | sed "s/^ //g" - | cut -d: -f 3)
		g1_type=$(echo "${item}" | cut -d, -f 2 | sed "s/^ //g" - | cut -d: -f 1)
		if [ "${g1_type}" = "${EXTERNAL_STORAGE_DEVICE}" ] && [ "${g1_part}" = "data" ]; then
			g1_has_data=1
			g1_data_start=$(echo "${item}" | cut -d, -f 3 | sed "s/^ //g" -)
		elif [ "${g1_type}" = "${EXTERNAL_STORAGE_DEVICE}" ] && [ "${g1_part}" = "secondary_gpt" ]; then
			g1_start=$(echo "${item}" | cut -d, -f 3 | sed "s/^ //g" -)
			g1_size=$(echo "${item}" | cut -d, -f 4 | sed "s/^ //g" -)
			g1_secondary_start=${g1_start}
			g1_expected_bytes=$((g1_start + g1_size))
		fi
	done
	if [ "${g1_has_data}" = "1" ]; then
		g1_disk="/dev/$(get_disk_name "${external_device}")"
		[ -b "${g1_disk}" ] || { print_at_end "Error: G1 NVMe ${g1_disk} is unavailable"; exit 1; }
		[ -n "${g1_data_start}" ] && [ -n "${g1_expected_bytes}" ] || { print_at_end "Error: G1 data layout has incomplete GPT geometry"; exit 1; }
		g1_actual_bytes=$(blockdev --getsize64 "${g1_disk}")
		if [ "${g1_actual_bytes}" -ne "${g1_expected_bytes}" ]; then
			print_at_end "Error: refusing to rewrite G1 GPT: XML expects ${g1_expected_bytes} bytes but ${g1_disk} has ${g1_actual_bytes}. Regenerate the layout from the exact blockdev --getsz value; no GPT changes were made."
			exit 1
		fi
		g1_data_node="${g1_disk}p16"
		if [ -b "${g1_data_node}" ]; then
			g1_sys_start="/sys/class/block/${g1_data_node##*/}/start"
			[ -r "${g1_sys_start}" ] || { print_at_end "Error: cannot verify existing G1 data partition start"; exit 1; }
			g1_current_start=$(($(cat "${g1_sys_start}") * 512))
			g1_current_size=$(blockdev --getsize64 "${g1_data_node}")
			g1_current_end=$((g1_current_start + g1_current_size))
			if [ "${g1_current_start}" -ne "${g1_data_start}" ] || [ "${g1_current_end}" -gt "${g1_secondary_start}" ] || [ $((g1_secondary_start - g1_current_end)) -ge 4096 ]; then
				print_at_end "Error: refusing to rewrite G1 GPT: existing ${g1_data_node} geometry does not match the generated layout (APP_SIZE or partition layout changed); no GPT changes were made."
				exit 1
			fi
		fi
	fi'

    _tmp=$(mktemp)
    awk -v blk="$_blk" '
        /# The GPT must be the first partition flashed/ && !done { print blk; done=1 }
        { print }
    ' "$_f" >"$_tmp"
    grep -qF "$_marker" "$_tmp" || { rm -f "$_tmp"; die "failed to add exact-NVMe-size guard"; }
    $SUDO install -m 0755 "$_tmp" "$_f"
    rm -f "$_tmp"
    log "  installed exact-NVMe-size guard before GPT writes"
fi
