# Building the default-Chinese payloads

`abl_signed-SM{8250,8550,8650,8750}.elf` are OpenABL 1.1 built from the
upstream v1.1 source with `default-zh.patch` applied. Each image's SHA-256 is
recorded next to it in `abl_signed-<SOC>.elf.sha256`; verify against those
files rather than rebuilding.

## Inputs

| Item | Value |
|---|---|
| Source archive | `openabl-v1.1-source.tar.xz` (upstream v1.1 release asset) |
| Source URL | <https://github.com/OpenHandheldCollective/OpenABL/releases/download/v1.1/openabl-v1.1-source.tar.xz> |
| Source SHA-256 | `9aca67ccfc258dbc7baf5db2d3ee43d93780d6f577260524e269e0e182dc8b80` |
| Patch | `default-zh.patch` (this directory) |

## Steps

1. Verify and unpack the archive:

   ```sh
   echo '9aca67ccfc258dbc7baf5db2d3ee43d93780d6f577260524e269e0e182dc8b80  openabl-v1.1-source.tar.xz' | sha256sum -c -
   tar -xf openabl-v1.1-source.tar.xz
   ```

2. Enter the single top-level directory the archive creates and apply the
   patch:

   ```sh
   patch -p1 < /path/to/default-zh.patch
   ```

3. Build all four chipsets with the upstream build script from that directory,
   which requires Git and Docker (it builds inside the project's container
   image):

   ```sh
   bash build.sh sm8250 sm8550 sm8650 sm8750 --clean
   ```

4. Check each generated `abl_signed-<SOC>.elf` against the pinned digest next
   to this file, for example:

   ```sh
   sha256sum build/out/abl_signed-SM8250.elf
   ```

## Reproducibility

The build is not promised to be bit-for-bit reproducible: signature bytes and
toolchain timestamps vary between runs, so a fresh build can differ from the
packaged image without being wrong. Treat `*.sha256` here as the record of the
shipped payloads, and use the steps above to reproduce the source state, not a
guaranteed digest.

The patch only changes the fallback language: Simplified Chinese is used when
no valid language setting is stored, and an explicitly saved English or Chinese
choice is kept. English remains selectable in the menu.
