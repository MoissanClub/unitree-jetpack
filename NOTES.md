# Flash internals — session notes (JetPack 6.2.2 / L4T R36.5.0)

Verified against the code in `bsp/6.2.2/Linux_for_Tegra/`. Line refs are that tree.

## Architecture
- `flash.sh` writes over raw RCM/USB, which only reaches storage the Tegra boot chain
  controls (QSPI, eMMC/SD). It **cannot write NVMe** — hence `l4t_initrd_flash.sh`,
  which uses `flash.sh` internally only to *generate* images, then RCM-boots a
  recovery initrd and writes QSPI + NVMe from the target over USB-RNDIS/NFS.
- `-p "..."` options go only to the **internal (QSPI) image stage**; the NVMe stage is
  a separate flash.sh run (`EXTOPTIONS` inherits `-p` only under `--external-only`).
  So `--no-systemimg` inside `-p` never affects the NVMe rootfs.
- `flash qspi` needs `--qspi-only`: a top-level `-c` without `--external-device` is
  silently discarded, and without the flag the initrd runs an unguarded
  `parted mklabel` on the absent SD card and aborts before writing QSPI.

## system.img is a host-side intermediate — never written to disk byte-for-byte
- Host: external-stage flash.sh builds `bootloader/system.img.raw` (full ext4 image,
  sparse file via `truncate`). Then `l4t_create_images_for_kernel_flash.sh:362-381`
  loop-mounts it and re-packs the files into a **zstd tarball** — shipped to the board
  as `images/external/system.img` (misleading name; it's a tar.zst).
- Target picks the write path by **magic bytes** (`l4t_flash_from_kernel.sh:997-1035`):
  our tarball → `mkfs.ext4 -F` + untar. So NVMe writes ≈ rootfs content (~6.5GB),
  independent of image/partition size.
- The full-partition zero-write danger exists only on the `--sparse` path
  (`erase_partition`: blkdiscard, `dd if=/dev/zero` fallback). We don't use it.
- Only partition-size-dependent writes: ext4 metadata + post-boot `ext4lazyinit`
  inode-table zeroing (~16MB per 1GiB of partition).
- Built rootfs (`Linux_for_Tegra/rootfs`, patched): **6.7GB**. flash.sh fails loudly
  at build time if it outgrows the image size.

## Sizing precedence
- flash.sh sources the board conf (:2146) **before** parsing CLI (`-S` at :2315), so
  `-S` (our `APP_SIZE`) always overrides `ROOTFSSIZE` in `p3767.conf.common`.
- `-S` also sets APP's allocation_attribute to 0x8 (:4391-4396) — size + no-expand are
  coupled *only* through `-S`. Patching `ROOTFSSIZE` (patches/15, 8GiB) resizes the
  image while leaving the XML's expand attribute alone. With `APP_SIZE` set, that 8GiB
  is dormant fallback.

## GPT / expand behavior on target (`create_gpt`, l4t_flash_from_kernel.sh:1048-1181)
- Every `flash all` **unconditionally wipes the partition table** (`parted mklabel gpt`)
  and rewrites it from the layout XML. Partitions not in the XML are erased from the
  table — auto-expand never "fails" on them; they're already gone. Expanded-over data
  is then destroyed by mkfs; past a pinned APP the blocks merely become orphaned.
- XML sizes are nominal (`EXT_NUM_SECTORS` defaults to 57GiB): on target, parted "Fix"
  moves the backup GPT to the real disk end, then the partition whose flash.idx entry
  carries `expand` (from attribute bit 0x800) is `resizepart`-grown to fill the disk.
- Partition `id` in the XML = GPT slot = device node number. APP is `id=1` →
  `/dev/nvme0n1p1` even though it's physically last.

## G1 layout (patches/16 → `flash_l4t_t234_nvme_g1.xml`)
- APP: 0x808→0x8, pinned at `APP_SIZE` (16GiB). New `data` partition (id 16 →
  `/dev/nvme0n1p16`, nominal 1GiB, **no `<filename>`**) sits after APP with 0x808 —
  it expands to fill any-size NVMe; no hardcoded disk size.
- Imageless partitions are skipped at write time, and the rewritten GPT reproduces
  identical offsets → `data` contents survive reflashes. Format once:
  `mkfs.ext4 /dev/nvme0n1p16`. Changing `APP_SIZE`/layout moves its offsets and
  orphans the contents — keep backups.
- Unverified: whether `backup` would try to dump the (huge) data partition; check
  `l4t_backup_restore.sh` before using it on this layout.
