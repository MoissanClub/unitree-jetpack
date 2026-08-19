# 16-bsp-nvme-data-partition.sh — G1 NVMe layout: fixed APP + persistent data partition.
#
# WHAT:  generates tools/kernel_flash/flash_l4t_t234_nvme_g1.xml (the NVME_XML in
#        version.env) from NVIDIA's flash_l4t_t234_nvme.xml with two changes:
#          - APP: allocation_attribute 0x808 -> 0x8, so APP no longer expands; its
#            size is the APPSIZE placeholder, filled from APP_SIZE (-S) or ROOTFSSIZE.
#          - new "data" partition (id 16 -> /dev/nvme0n1p16) between APP and the
#            secondary GPT, with 0x808, so the on-target flasher expands IT to fill
#            the NVMe. No hardcoded disk size — works for any NVMe.
# WHY:   the data partition has no <filename>, so flashing skips writing it: every
#        reflash recreates the identical GPT (same offsets) and the contents survive.
#        Format it ONCE by hand (mkfs.ext4 /dev/nvme0n1p16); its nominal 1GiB in the
#        XML is only a placeholder until the on-flash expand.
#
# Sourced by patch_bsp() with: $LFT $SUDO and log() in scope.

_src="$LFT/tools/kernel_flash/flash_l4t_t234_nvme.xml"
_dst="$LFT/tools/kernel_flash/flash_l4t_t234_nvme_g1.xml"
[ -f "$_src" ] || die "stock NVMe layout not found: $_src"

_blk='        <partition name="data" id="16" type="data">
            <allocation_policy> sequential </allocation_policy>
            <filesystem_type> basic </filesystem_type>
            <size> 1073741824 </size>
            <file_system_attribute> 0 </file_system_attribute>
            <allocation_attribute> 0x808 </allocation_attribute>
            <align_boundary> 16384 </align_boundary>
            <percent_reserved> 0 </percent_reserved>
            <description> G1: persistent user data. No filename, so flashing never
              writes it and its contents survive reflashes; expands on-flash to fill
              the NVMe. Format once by hand: mkfs.ext4 /dev/nvme0n1p16 </description>
        </partition>'

# sed first (only APP carries 0x808 in the stock file), then insert the data block.
# Always regenerated from the pristine stock file, so re-running is a no-op.
sed 's/ 0x808 / 0x8 /' "$_src" \
    | awk -v blk="$_blk" '/<partition name="secondary_gpt"/ {print blk} {print}' \
    | $SUDO tee "$_dst" >/dev/null

grep -q 'name="data" id="16"' "$_dst" || die "data partition missing in $_dst"
grep -A5 'name="APP"' "$_dst" | grep -q '<allocation_attribute> 0x8 <' \
    || die "APP still has the expand attribute in $_dst"
log "  NVMe layout: flash_l4t_t234_nvme_g1.xml (APP fixed, data partition expands)"
