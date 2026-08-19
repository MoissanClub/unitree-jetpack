# 15-bsp-rootfs-size.sh — shrink the host-built system.img to 8GiB.
#
# WHAT:  sets ROOTFSSIZE=8GiB in p3767.conf.common (NVIDIA ships 55GiB).
# WHY:   the built rootfs is only ~6.5GB, so 55GiB just bloats the host-side image
#        build. This is the fallback when APP_SIZE is empty. Final APP/data allocation
#        attributes are selected by patches/16: empty APP_SIZE keeps stock APP expand;
#        non-empty APP_SIZE pins APP and adds the exact-capacity data partition.
#
# Sourced by apply_patches() with: $LFT $SUDO and log() in scope.

_f="$LFT/p3767.conf.common"
if grep -q '^ROOTFSSIZE=8GiB;' "$_f"; then
    log "  ROOTFSSIZE already 8GiB"
else
    $SUDO sed -i 's/^ROOTFSSIZE=[0-9]\+GiB;/ROOTFSSIZE=8GiB;/' "$_f"
    grep -q '^ROOTFSSIZE=8GiB;' "$_f" || die "failed to set ROOTFSSIZE in $_f"
    log "  ROOTFSSIZE 55GiB -> 8GiB (fallback when APP_SIZE is empty)"
fi
