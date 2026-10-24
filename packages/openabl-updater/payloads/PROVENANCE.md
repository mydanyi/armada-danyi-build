# Provenance

## Base

| Item | Value |
|---|---|
| Project | OpenABL (<https://github.com/OpenHandheldCollective/OpenABL>) |
| Tag | `v1.1` |
| Commit | `8f09253f8f93e7d9ff0b5baf3bda87976f0c54ac` |
| Source archive | <https://github.com/OpenHandheldCollective/OpenABL/releases/download/v1.1/openabl-v1.1-source.tar.xz> |
| Source SHA-256 | `9aca67ccfc258dbc7baf5db2d3ee43d93780d6f577260524e269e0e182dc8b80` |

## Patch

`default-zh.patch` changes two fallbacks in the upstream source:

- `Core/Settings.c`: a fresh settings block defaults `Language` to
  `LANG_ZH_HANS`.
- `Menu/Menu.c`: `MenuLoadPrefs` falls back to `LANG_ZH_HANS` instead of
  `LANG_EN` when no stored language is valid.

A stored English or Chinese selection is still honoured, and the menu keeps
both languages selectable. Nothing else in the firmware is changed, so the
payloads still report version 1.1.

## Packaged payloads

Variant: `danyi-default-zh`. Version: 1.1. Size: 532480 bytes each.

| SoC | SHA-256 |
|---|---|
| SM8250 | `2efd842b60e99985b0da6672915b388675ad0f45ec63f7ac6c56e51cca895aea` |
| SM8550 | `84ff543ff0918c14ae506c8947c6636144157988ea55919d977778dfb9da1a66` |
| SM8650 | `f424226638fcbcf1e13ff29e6431a768cab85c4d26904c35d7e4eb0fa2d7c772` |
| SM8750 | `9379ef0414742ce4dba2373c6bc89550a747c5a8d18d2b455762133763baca86` |

Each digest matches the sibling `abl_signed-<SOC>.elf.sha256`, which the RPM
build verifies before generating its manifest.

## Acceptance status

The payloads were built successfully from the pinned source and patch. Booting
and flashing them on real devices has not been confirmed, so no device-level
acceptance is claimed here.
