# unitree-jetpack

Build/flash custom JetPack images for the Unitree G1 head unit
(Jetson Orin NX 16GB, p3767 module on a p3768-class carrier).

## Layout
- `g1_custom_jetpack.sh` — single entry point: init / flash / backup / restore / status / clean
- `versions/<ver>/version.env` — per-JetPack URLs, `BOARD_CONF`, `QSPI_CFG`, `NVME_XML`, `ROOT_DEV`, `KVER`
- `versions/<ver>/patches/*.sh` — the COMPLETE set of BSP+rootfs changes, sourced in sorted order by `apply_patches`
- `versions/_lib/rootfs.sh` — shared patch helpers (`in_image`, `apt_install`, …)
- `bsp/<ver>/Linux_for_Tegra/` — extracted+patched NVIDIA BSP (git-ignored; `.g1-init-done` marks a finished init)
- `downloads/<ver>/` — cached NVIDIA tarballs (git-ignored); `backups/` — partition dumps (git-ignored)
- `docs/` — usb-mapping, unitree-stack, recovery-mode, wifi, tips

## Key behavior (read the script, don't guess)
- Focus version: JetPack 6.2.2 = L4T 36.5.0. NVIDIA tooling lives in `bsp/6.2.2/Linux_for_Tegra/`

## Flash behavior (verified against the R36.5.0 tooling)
- The G1 has QSPI (64MiB firmware) + NVMe (rootfs). No eMMC/SD. `flash.sh` alone can't
  write NVMe over RCM — that's why everything goes through `l4t_initrd_flash.sh`, which
  uses `flash.sh` internally only to generate images, then writes from a recovery initrd
  over USB-RNDIS.
- `flash all`: the `-p "-c $QSPI_CFG --no-systemimg"` options apply only to the internal
  (QSPI) image stage; the NVMe stage is a separate flash.sh run that always builds the
  full rootfs. Matches NVIDIA's README_initrd_flash.txt Workflow 4.
- `flash qspi`: must use `--qspi-only`. A top-level `-c` without `--external-device` is
  silently ignored, and without the flag the initrd aborts trying to partition the absent
  SD card.
- APP (rootfs) is flashed as mkfs.ext4 + untar of a zstd tarball (the shipped
  `images/external/system.img` is that tarball, despite the name). `system.img`/`.raw`
  in `bootloader/` are host-side intermediates, never written to the NVMe byte-for-byte —
  NVMe writes ≈ rootfs content (~6.5GB) no matter the image size.
- system.img/APP size: `APP_SIZE` in `version.env` (16GiB) is passed as `-S`, which
  overrides `ROOTFSSIZE` from `p3767.conf.common` (CLI parses after the conf is
  sourced) — the 8GiB from `patches/15-bsp-rootfs-size.sh` is only the fallback when
  `APP_SIZE` is empty.
- Layout: `patches/16-bsp-nvme-data-partition.sh` generates the G1-specific `NVME_XML`
  from NVIDIA's pristine XML. With `APP_SIZE` set, it requires the exact target value
  from `blockdev --getsz /dev/nvme0n1`, pins APP, and adds imageless data p16. The exact
  capacity places the secondary GPT at the physical disk end instead of NVIDIA's unsafe
  57GiB nominal boundary. `patches/17-bsp-nvme-exact-size-guard.sh` checks capacity and
  existing p16 geometry before any GPT write. `EXT_NUM_SECTORS` is intentionally blank
  until measured, so persistent-data initialization currently refuses to proceed.
- With `APP_SIZE` empty, patch 16 emits the stock layout: no p16, 8GiB system image, and
  APP auto-expands to the NVMe end. This is a full-wipe mode. See `NOTES.md` for the mode
  matrix, partition list, secondary-GPT analysis, and the persistence contract.
