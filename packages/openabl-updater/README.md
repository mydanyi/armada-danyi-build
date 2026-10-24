# openabl-updater

Ships OpenABL bootloader images and updates the device's ABL to them at shutdown.

The packaged images are the default-Chinese (`danyi-default-zh`) variant of
OpenABL 1.1, built locally for each supported chipset (SM8250, SM8550, SM8650,
SM8750). They are not downloaded from the upstream release: the four payloads
and their pinned `.sha256` files live in `payloads/` and are checked during the
RPM build. `payloads/BUILD.md` records how they were built, and
`payloads/PROVENANCE.md` records the base commit, patch, and exact digests.

| SoC | Packaged SHA-256 |
|---|---|
| SM8250 | `2efd842b60e99985b0da6672915b388675ad0f45ec63f7ac6c56e51cca895aea` |
| SM8550 | `84ff543ff0918c14ae506c8947c6636144157988ea55919d977778dfb9da1a66` |
| SM8650 | `f424226638fcbcf1e13ff29e6431a768cab85c4d26904c35d7e4eb0fa2d7c772` |
| SM8750 | `9379ef0414742ce4dba2373c6bc89550a747c5a8d18d2b455762133763baca86` |

| Path | Purpose |
|---|---|
| `/usr/lib/openabl-updater/abl_signed-<SOC>.elf` | OpenABL images |
| `/usr/lib/openabl-updater/manifest` | Packaged name, version, variant, and each image's SHA-256 |
| `/usr/lib/openabl-updater/legacy-releases.tsv` | Known ABL builds, by hash |
| `/usr/lib/openabl-updater/personal-migrations.tsv` | Approved older builds for this variant, bound to the target hash |
| `/usr/libexec/openabl-updater/abl-version` | Identifies an installed or booted ABL |
| `/usr/libexec/openabl-updater/armada-abl-update` | Writes the image to `abl_a` and `abl_b` |
| `/usr/libexec/openabl-updater/armada-abl-finalize` | Runs the updater at shutdown, after `/KERNEL` is synced |
| `/usr/share/doc/OpenABL/openabl-v1.1-source.tar.xz` | Corresponding upstream source |
| `/usr/share/doc/OpenABL/default-zh.patch` | The only source change in these images |
| `/usr/share/doc/OpenABL/BUILD.md`, `PROVENANCE.md`, `OpenABL-LICENSE` | Build steps, provenance, license |

## Update policy

Updates are always on. At shutdown, each ABL copy is checked in this order:

1. **Already the packaged image:** nothing to do.
2. **Listed in `legacy-releases.tsv`:** the hash decides, whatever the firmware
   reports. ROCKNIX and older OpenABL are replaced. A newer release, another
   chipset's image, or the packaged version with different bytes is refused.
3. **Not listed:** the booted OpenABL's reported version decides (ESRT or
   `LoaderInfo`). Older is replaced. The same or newer version is a custom or CI
   build and is left alone. With no report, the copy is refused.

The variant also carries `personal-migrations.tsv`: an explicit list of older
builds that may be replaced even though `legacy-releases.tsv` would not identify
them. Each row is tied to the target image's SHA-256, so the list stops applying
when the packaged payload changes. Rows are only consulted when the manifest
reports the `danyi-default-zh` variant.

`legacy-releases.tsv` covers ROCKNIX and certain OpenABL releases, which expose no UEFI
variables when booting `/KERNEL`. Later releases report their own version, so
they only need rows if one misreports it.

Reading UEFI variables needs the kernel patch that allows QSEECOM on these
chipsets (from OpenABL's `Linux/`).

## Language default

The images fall back to Simplified Chinese only when no valid language setting
is stored. A user who selects English in the boot menu keeps English, and the
menu still offers both languages.

## Bumping OpenABL

Replace the files in `payloads/` (image, `.sha256`, and the patch if the source
changes), update `openabl_source_url`/`openabl_source_sha256` and
`openabl_version` in `openabl-updater.spec`, refresh `PROVENANCE.md`, and add a
changelog entry. `personal-migrations.tsv` is bound to the target digest, so
re-check it whenever the payloads change.

`sdcard/` holds the scripts for flashing from Android.
`post_process/finalize-armada-image.sh` copies it to the image's ESP.
