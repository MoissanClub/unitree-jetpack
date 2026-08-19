# 16-bsp-nvme-data-partition.sh — generate the selected G1 NVMe layout.
#
# WHAT:  generates tools/kernel_flash/flash_l4t_t234_nvme_g1.xml (the NVME_XML in
#        version.env) from NVIDIA's pristine flash_l4t_t234_nvme.xml.
#          - APP_SIZE empty: keep the stock layout (APP has 0x808 and expands; no p16).
#          - APP_SIZE set: require exact EXT_NUM_SECTORS; pin APP at -S/APP_SIZE and add
#            imageless data (id 16 -> p16) with 0x808. tegraparser expands data up to
#            the secondary GPT at the exact physical disk end, so the target does not
#            relocate GPT or resize data. Reflashing recreates identical GPT metadata
#            outside p16 and skips its payload. Format p16 exactly once.
#
# SAFETY: a merely nominal "2TB" value is unsafe. patches/17 validates the configured
# exact byte size on-target before any `parted mklabel` or GPT image write.
#
# Sourced by apply_patches() with: version.env + $LFT $SUDO and log()/die() in scope.

_src="$LFT/tools/kernel_flash/flash_l4t_t234_nvme.xml"
_dst="$LFT/tools/kernel_flash/flash_l4t_t234_nvme_g1.xml"
[ -f "$_src" ] || die "stock NVMe layout not found: $_src"

if [ -z "${APP_SIZE:-}" ]; then
    # Stock behavior. If an exact device size is supplied, bake it in; otherwise leave
    # NVIDIA's placeholder, which flash.sh replaces with its 57GiB nominal default.
    if [ -n "${EXT_NUM_SECTORS:-}" ]; then
        case "$EXT_NUM_SECTORS" in *[!0-9]*) die "EXT_NUM_SECTORS must be decimal sectors";; esac
        [ "$EXT_NUM_SECTORS" -gt 0 ] || die "EXT_NUM_SECTORS must be greater than zero"
        sed "s/EXT_NUM_SECTORS/$EXT_NUM_SECTORS/" "$_src" | $SUDO tee "$_dst" >/dev/null
    else
        $SUDO cp "$_src" "$_dst"
    fi
    grep -A5 'name="APP"' "$_dst" | grep -q '<allocation_attribute> 0x808 <' \
        || die "stock APP expand attribute missing in $_dst"
    ! grep -q 'name="data"' "$_dst" || die "unexpected data partition in stock APP mode"
    log "  NVMe layout: stock APP auto-expand (no persistent data partition)"
    return 0
fi

[ -n "${EXT_NUM_SECTORS:-}" ] \
    || die "APP_SIZE=$APP_SIZE requires exact EXT_NUM_SECTORS; on the booted G1 run: blockdev --getsz /dev/nvme0n1"
case "$EXT_NUM_SECTORS" in *[!0-9]*) die "EXT_NUM_SECTORS must be decimal sectors, got: $EXT_NUM_SECTORS";; esac
[ "$EXT_NUM_SECTORS" -gt 0 ] \
    || die "EXT_NUM_SECTORS must be greater than zero"

_blk='        <partition name="data" id="16" type="data">
            <allocation_policy> sequential </allocation_policy>
            <filesystem_type> basic </filesystem_type>
            <size> 1073741824 </size>
            <file_system_attribute> 0 </file_system_attribute>
            <allocation_attribute> 0x808 </allocation_attribute>
            <align_boundary> 16384 </align_boundary>
            <percent_reserved> 0 </percent_reserved>
            <description> G1 persistent data. Imageless, fixed geometry for the exact
              configured NVMe; format once: mkfs.ext4 -L models /dev/nvme0n1p16 </description>
        </partition>'

# Only APP carries 0x808 in the stock file. tegraparser applies data's new 0x808
# against the exact device size baked here, not the unsafe 57GiB default.
sed -e 's/ 0x808 / 0x8 /' -e "s/EXT_NUM_SECTORS/$EXT_NUM_SECTORS/" "$_src" \
    | awk -v blk="$_blk" '/<partition name="secondary_gpt"/ {print blk} {print}' \
    | $SUDO tee "$_dst" >/dev/null

grep -q 'name="data" id="16"' "$_dst" || die "data partition missing in $_dst"
grep -q "num_sectors=\"$EXT_NUM_SECTORS\"" "$_dst" \
    || die "exact NVMe sector count missing in $_dst"
grep -A5 'name="APP"' "$_dst" | grep -q '<allocation_attribute> 0x8 <' \
    || die "APP still has the expand attribute in $_dst"
log "  NVMe layout: APP=$APP_SIZE + persistent p16 on exactly $EXT_NUM_SECTORS sectors"
