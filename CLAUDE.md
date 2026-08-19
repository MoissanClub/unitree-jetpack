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
- Layout: `patches/16-bsp-nvme-data-partition.sh` generates `flash_l4t_t234_nvme_g1.xml`
  (= `NVME_XML`): APP pinned at APP_SIZE (attr 0x8), and a `data` partition (id 16 ->
  /dev/nvme0n1p16, no image) carries the 0x808 expand attribute instead — it grows to
  fill the NVMe on flash, is never written, and survives reflashes. Note `flash all`
  still wipes+rewrites the whole GPT every time (`create_gpt` runs `mklabel gpt`); the
  data partition survives only because the layout recreates identical offsets.
