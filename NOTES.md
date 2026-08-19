# Flash internals — verified notes (JetPack 6.2.2 / L4T R36.5.0)

Verified against the NVIDIA code in `bsp/6.2.2/Linux_for_Tegra/` and the generated
partition table. These are implementation notes, not assumptions based on option names.

## Recommended result

Use a fixed NVIDIA `APP` rootfs (`/dev/nvme0n1p1`) followed by an imageless ext4 data
partition (`/dev/nvme0n1p16`) for downloaded models. Generate a G1-specific XML from
NVIDIA's pristine XML instead of maintaining a copied vendor file, and bake in the exact
physical NVMe sector count. This is implemented by patches 16 and 17.

`EXT_NUM_SECTORS` is intentionally an empty placeholder. On the booted G1, obtain the
exact value and put it in `versions/6.2.2/version.env` before running `init` or `flash all`:

```bash
sudo blockdev --getsz /dev/nvme0n1
```

`blockdev --getsz` reports 512-byte sectors, matching the XML's `sector_size="512"`.
Do not derive the number from the advertised capacity: different drives sold as “2 TB”
can expose different exact sector counts.

## Supported layout modes

| `APP_SIZE` | `EXT_NUM_SECTORS` | Generated layout and `flash all` behavior |
|---|---|---|
| empty | empty | Stock NVIDIA layout, no p16. The system image uses the patched 8 GiB `ROOTFSSIZE`; APP retains `0x808` and expands to the actual NVMe end on target. Full wipe. |
| empty | exact sector count | Stock layout, no p16, with exact disk geometry baked into the generated XML. APP consumes the remaining space while GPT images are generated. Full wipe. |
| empty | nonnumeric or zero | Rejected during `init`. |
| fixed size, e.g. `16GiB` | exact sector count | Persistent-data mode: fixed APP p1 plus data p16 filling the remainder. Full flash recreates identical GPT geometry and rewrites boot/rootfs images, but does not write p16. |
| fixed size | empty, nonnumeric, or zero | Rejected during `init`; no unsafe persistent layout is generated. |
| fixed size | valid but for another drive | Generated successfully, but patch 17 rejects it on the target before `parted mklabel` or either GPT write. |

The current checked-in values select persistent-data mode but deliberately leave
`EXT_NUM_SECTORS=""`, so initialization stops until the G1 value is filled in.

After the first successful persistent-layout flash, format the data partition once:

```bash
sudo mkfs.ext4 -L models /dev/nvme0n1p16
```

Thereafter, keep `APP_SIZE`, `EXT_NUM_SECTORS`, and every partition before/after p16
unchanged. Patch 17 checks the disk capacity and, when p16 already exists, its start/end
geometry before a full flash rewrites GPT. A capacity or layout mismatch aborts before
any GPT change.

## Supported flash operations

| Operation | GPT/NVMe effect |
|---|---|
| `./g1_custom_jetpack.sh -j 6.2.2 flash qspi` | Uses `--qspi-only`; writes QSPI firmware only and does not touch NVMe. |
| `./g1_custom_jetpack.sh -j 6.2.2 flash all` | No `-k`: recreates the external GPT and writes every image-backed NVMe partition, including APP and ESP-related boot content. Imageless partitions, including data p16, receive no payload. Persistent p16 survives only under the exact-layout contract above. |
| NVIDIA `--external-only -k APP` (not exposed by this wrapper) | Does not call `create_gpt`; formats/writes only the existing APP partition. It leaves ESP, other boot partitions, GPT, and p16 untouched. Useful for rootfs-only work, but it does not update matched boot artifacts. |
| NVIDIA `--external-only` without `-k` | Still recreates the external GPT and performs a full external-device flash. `--external-only` does not mean “APP only.” |

The best way to update APP together with its matching ESP/kernel/recovery artifacts while
preserving models is therefore `flash all` with the fixed, exact persistent layout and
the preflight guard—not a partial `-k APP` flash.

## NVMe partition map

In persistent-data mode the GPT partition numbers are:

| Node | GPT name | Written by a normal full flash? |
|---|---|---|
| p1 | `APP` (rootfs) | yes: mkfs.ext4 + rootfs untar |
| p2 | `A_kernel` | yes |
| p3 | `A_kernel-dtb` | yes |
| p4 | `A_reserved_on_user` | no filename; skipped |
| p5 | `B_kernel` | yes |
| p6 | `B_kernel-dtb` | yes |
| p7 | `B_reserved_on_user` | no filename; skipped |
| p8 | `recovery` | yes |
| p9 | `recovery-dtb` | yes |
| p10 | `esp` | yes |
| p11 | `recovery_alt` | no filename; skipped |
| p12 | `recovery-dtb_alt` | no filename; skipped |
| p13 | `esp_alt` | no filename; skipped |
| p14 | `UDA` | no filename; skipped |
| p15 | `reserved` | no filename; skipped |
| p16 | `data` (G1 addition) | no filename; skipped |

Partition number is the XML/GPT `id`, not physical order. NVIDIA deliberately assigns
APP `id="1"` even though it is physically after p2–p15, so Linux exposes the rootfs at
the stable `/dev/nvme0n1p1`. The custom data partition is physically after APP and uses
the next free GPT ID, 16.

## Why exact `EXT_NUM_SECTORS` matters

`EXT_NUM_SECTORS` controls the whole external-device boundary and therefore the position
of the secondary GPT; `APP_SIZE` controls APP and consequently p16's start. The generated
secondary GPT metadata contains the complete partition map, so its contents reflect
APP/data geometry even though its location is determined by total disk size.

NVIDIA's unset default is 119,537,664 sectors (about 57 GiB). With a larger real disk,
the target normally does this in `create_gpt()`:

1. `parted -s "${disk}" mklabel gpt`
2. write the generated primary GPT
3. write `gpt_secondary_9_0.bin` at the XML's nominal end
4. run `parted ... print` with `Fix` to move the secondary GPT to the real disk end
5. grow the partition carrying the `expand` attribute

That stock flow is acceptable when APP is being erased anyway. It is unsafe for a
persistent expanded p16: on the next flash, step 3 writes the nominal 57 GiB secondary
GPT inside p16 before `parted` moves it. Setting the exact sector count generates the
secondary GPT at the real end and expands p16 during host-side GPT generation, eliminating
that collision. Patch 17 additionally checks the actual target before step 1.

## Flash pipeline details

- `flash.sh` cannot directly write NVMe through raw RCM. `l4t_initrd_flash.sh` uses it to
  generate images, boots a recovery initrd, then writes QSPI/NVMe from the target over
  USB-RNDIS/NFS.
- `-p "..."` applies to the internal/QSPI image-generation stage. The external stage is
  separate, so `--no-systemimg` inside `-p` does not suppress the NVMe rootfs image.
- APP is NVIDIA's name for the rootfs partition. The host's `system.img.raw` is repacked
  as a zstd tar archive named `images/external/system.img`; the target detects the archive,
  runs `mkfs.ext4`, and untars it into APP. It is not dd-written byte-for-byte.
- `-S` is supplied only when `APP_SIZE` is nonempty. It overrides the board config's
  `ROOTFSSIZE` and changes APP to non-expanding allocation. With `APP_SIZE` empty, the
  patched 8 GiB `ROOTFSSIZE` is the image-size fallback and APP retains expansion.
- A normal full flash calls `create_gpt()` because no `-k partition` was supplied. It
  rewrites GPT first, then writes image-backed rows. Rows with no `<filename>` are skipped.

## Backup implication

R36 backup is not rootfs-only. It enumerates every NVMe partition: ext4 partitions are
tar+zstd archived, while non-ext4 partitions are read with `dd` and compressed. Once p16
is formatted ext4, a wrapper `backup` includes its model files and may therefore be large
and slow. Restore is destructive and restores the backed-up GPT/partitions.
