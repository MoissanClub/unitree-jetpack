# 12-bsp-bpmp-pcie-fix.sh — NVIDIA R36.5 BPMP PCIe initialization fix.
#
# WHAT:  fetches NVIDIA's checksum-pinned overlay_pcie.tbz2 Additional Files archive,
#        validates its complete set of T234 production BPMP firmware images, and installs
#        them over the stock copies in Linux_for_Tegra/bootloader. flash.sh selects the
#        correct image from the fused chip SKU; the G1's Orin NX 16GB uses TE980M.
# WHY:   NVIDIA publishes these replacements for an intermittent boot failure caused by
#        PCIe initialization failures on some Orin Nano/NX modules during power cycles or
#        reboots. BPMP runs before Linux, so this belongs in the BSP/QSPI payload, not rootfs.
#
# Sourced by apply_patches() with version.env ($NVIDIA_PCIE_BPMP_URL/_SHA256, $DOWNLOADS)
# + $LFT $SUDO $JP and fetch_verify()/log()/ok()/die() in scope.

[ -n "${NVIDIA_PCIE_BPMP_URL:-}" ] \
    || die "NVIDIA_PCIE_BPMP_URL not set in versions/$JP/version.env"
[ -n "${NVIDIA_PCIE_BPMP_SHA256:-}" ] \
    || die "NVIDIA_PCIE_BPMP_SHA256 not set in versions/$JP/version.env"
need tar

_archive="$DOWNLOADS/overlay_pcie_r${L4T_VER}.tbz2"
fetch_verify "$NVIDIA_PCIE_BPMP_URL" "$NVIDIA_PCIE_BPMP_SHA256" "$_archive"

_stage=$(mktemp -d "$DOWNLOADS/overlay-pcie.XXXXXX")
tar -xjf "$_archive" -C "$_stage" \
    || { rm -rf "$_stage"; die "failed to extract $(basename "$_archive")"; }
_src="$_stage/overlay_pcie/Linux_for_Tegra/bootloader"
_bpmp_files=(
    bpmp_t234-TA990SA-A1_prod.bin
    bpmp_t234-TE950M-A1_prod.bin
    bpmp_t234-TE980M-A1_prod.bin
    bpmp_t234-TE990M-A1_prod.bin
    bpmp_t234-TE992M-A1_prod.bin
)

for _fw in "${_bpmp_files[@]}"; do
    [ -f "$_src/$_fw" ] \
        || { rm -rf "$_stage"; die "missing BPMP firmware in NVIDIA archive: $_fw"; }
done
for _fw in "${_bpmp_files[@]}"; do
    $SUDO install -m 0644 "$_src/$_fw" "$LFT/bootloader/$_fw"
done
rm -rf "$_stage"

ok "NVIDIA BPMP PCIe fix installed (5 SKU images; Orin NX selects TE980M)"
