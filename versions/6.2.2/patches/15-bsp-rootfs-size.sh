# 15-bsp-rootfs-size.sh — shrink the host-built system.img to 8GiB.
#
# WHAT:  sets ROOTFSSIZE=8GiB in p3767.conf.common (NVIDIA ships 55GiB).
# WHY:   the built rootfs is only ~6.5GB, so 55GiB just bloats the host-side image
#        build. Unlike initrd-flash's -S option (which also pins the partition),
#        changing ROOTFSSIZE keeps APP's 0x808 allocation attribute, so on flash
#        the APP partition still auto-expands to fill the NVMe. APP is written as
#        mkfs + untar, so NVMe write volume is unchanged either way.
#
# Sourced by patch_bsp() with: $LFT $SUDO and log() in scope.

_f="$LFT/p3767.conf.common"
if grep -q '^ROOTFSSIZE=8GiB;' "$_f"; then
    log "  ROOTFSSIZE already 8GiB"
else
    $SUDO sed -i 's/^ROOTFSSIZE=[0-9]\+GiB;/ROOTFSSIZE=8GiB;/' "$_f"
    grep -q '^ROOTFSSIZE=8GiB;' "$_f" || die "failed to set ROOTFSSIZE in $_f"
    log "  ROOTFSSIZE 55GiB -> 8GiB (system.img only; APP still auto-expands on flash)"
fi
