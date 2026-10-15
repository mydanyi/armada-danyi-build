#!/usr/bin/env bash
#
# Contract test for personal-build/package-install.sh.
#
# Contract: bash package-install.sh INPUT_IMG_GZ OUTPUT_DIR PART_BYTES
#   - INPUT_IMG_GZ : real gzip stream (.img.gz) of a raw disk image
#   - OUTPUT_DIR   : destination dir (must not pre-exist / must be refused if it does)
#   - PART_BYTES   : 7z volume size in bytes
#
# The complete .img.gz is stored as-is (never decompressed) inside multi-volume
# 7z archives named <input-basename>.7z.001, .002, ...; extracting the first
# volume recovers the .img.gz byte-for-byte because 7zz auto-reads the remaining
# volumes. No raw .img is ever produced. The manifest lists the .img.gz hash and
# every volume hash, with no duplicate filename entries and no raw .img entry.
#
# No mocks, no loop devices, no network. Uses real 7zz to join the volumes.
# The helper exists but does not yet implement this contract, so this run is
# expected to be RED until the implementation matches.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../package-install.sh"

# Temp fixtures live under the caller's TMPDIR only; own mktemp + trap.
TMPDIR="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMPDIR%/}/install-7z-test.XXXXXX")"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok: %s\n' "$*"; }

# --- RED gate: helper must exist before any assertion can pass. ---
if [ ! -f "$HELPER" ]; then
  printf 'RED: missing helper %s\n' "$HELPER" >&2
  exit 1
fi

command -v 7zz >/dev/null 2>&1 || fail "real 7zz binary is required (no mocks)"

# --- Fixtures ---------------------------------------------------------------
# The installer input is a real gzip stream over ~192 KiB of random raw data.
# Random bytes are incompressible, so the .img.gz spans several volumes and is
# deliberately not an exact multiple of the volume size.
GZ_NAME="armada-TEST.img.gz"
RAW_NAME="armada-TEST.img"          # raw image: must never be produced
GZ="${WORK}/${GZ_NAME}"
SRC_BYTES=$((192 * 1024 + 777))
head -c "$SRC_BYTES" /dev/urandom | gzip -c > "$GZ"
GZ_HASH="$(sha256sum "$GZ" | awk '{print $1}')"

VOL_BYTES=65536
OUT="${WORK}/out"

# --- Valid run --------------------------------------------------------------
bash "$HELPER" "$GZ" "$OUT" "$VOL_BYTES" || fail "helper exited nonzero on valid gzip input"

VOL_PREFIX="${GZ_NAME}.7z"
FIRST="${OUT}/${VOL_PREFIX}.001"
[ -f "$FIRST" ] || fail "expected first volume ${FIRST}"

shopt -s nullglob
VOLS=("$OUT/${VOL_PREFIX}."*)
shopt -u nullglob
[ "${#VOLS[@]}" -ge 2 ] || fail "expected >=2 volumes, found ${#VOLS[@]}"
ok "volumes: ${#VOLS[@]}"

for v in "${VOLS[@]}"; do
  sz="$(stat -c %s "$v")"
  [ "$sz" -le "$VOL_BYTES" ] || fail "volume $(basename "$v") exceeds ${VOL_BYTES} bytes ($sz)"
done
ok "all volumes <= ${VOL_BYTES} bytes"

# --- Real 7zz must auto-join the first volume and reproduce the .img.gz ------
JOINED="${WORK}/joined.img.gz"
7zz x -so "$FIRST" > "$JOINED" || fail "7zz failed to join volumes from the first volume"
cmp -s "$GZ" "$JOINED" || fail "joined output != original gzip ${GZ_NAME}"
ok "7zz -so join matches the original .img.gz byte-for-byte"

# --- 7zz l: the archive holds only the basename .img.gz, never a raw .img ----
ENTRIES="$(7zz l -slt -- "$FIRST" | awk '/^----------/{seen=1; next} seen && /^Path = /{sub(/^Path = /, ""); print}')"
ENTRY_COUNT="$(printf '%s\n' "$ENTRIES" | grep -c . || true)"
[ "$ENTRY_COUNT" -eq 1 ] || fail "archive must hold exactly one entry, found ${ENTRY_COUNT}"
[ "$ENTRIES" = "$GZ_NAME" ] || fail "archive entry must be the basename gz (${GZ_NAME}), found: ${ENTRIES}"
case "$ENTRIES" in
  *.img.gz) : ;;
  *) fail "archive entry is not an .img.gz: ${ENTRIES}" ;;
esac
case "$ENTRIES" in
  *.img) fail "archive must not contain a raw .img entry: ${ENTRIES}" ;;
esac
ok "7zz l: archive holds only ${GZ_NAME}"

# --- SHA256SUMS -------------------------------------------------------------
SUMS="${OUT}/SHA256SUMS"
[ -f "$SUMS" ] || fail "expected SHA256SUMS in output"

grep -q -- "$GZ_HASH" "$SUMS" || fail "SHA256SUMS must list the .img.gz hash"

for v in "${VOLS[@]}"; do
  base="$(basename "$v")"
  grep -qE "[[:space:]]\*?${base//./\\.}\$" "$SUMS" || fail "SHA256SUMS missing volume entry ${base}"
done
ok "SHA256SUMS lists the .img.gz hash and every volume"

# No raw .img hash may appear in the manifest.
RAW_RE="${RAW_NAME//./\\.}"
! grep -Eq "([[:space:]]|\*)${RAW_RE}\$" "$SUMS" || fail "SHA256SUMS must not list a raw .img entry"

# No filename may be listed twice.
mapfile -t SUM_NAMES < <(awk '{ n=$NF; sub(/^\*/, "", n); print n }' "$SUMS")
if [ "${#SUM_NAMES[@]}" -gt 0 ]; then
  DUPES="$(printf '%s\n' "${SUM_NAMES[@]}" | sort | uniq -d)"
  [ -z "$DUPES" ] || fail "SHA256SUMS has duplicate filename entries: ${DUPES}"
fi
ok "SHA256SUMS has no raw .img entry and no duplicate filename entries"

# Raw image must NOT be shipped in the output directory.
[ ! -e "$OUT/${RAW_NAME}" ] || fail "raw ${RAW_NAME} must not be published"

# Verify checksums after filtering out the .img.gz entry: the gz ships inside
# the volumes, so it is not a file in the output directory.
FILTERED="${WORK}/SHA256SUMS.volumes"
GZ_RE="${GZ_NAME//./\\.}"
grep -vE "([[:space:]]|\*)${GZ_RE}\$" "$SUMS" > "$FILTERED" || fail "no volume entries in SHA256SUMS"
[ -s "$FILTERED" ] || fail "filtered volume checksum list is empty"
( cd "$OUT" && sha256sum -c "$FILTERED" ) >/dev/null || fail "volume checksums do not verify"
ok "volume checksums verify (with .img.gz entry filtered)"

# --- Source gzip is untouched ------------------------------------------------
GZ_HASH_AFTER="$(sha256sum "$GZ" | awk '{print $1}')"
[ "$GZ_HASH" = "$GZ_HASH_AFTER" ] || fail "source gzip changed during packaging"
ok "source gzip hash unchanged"

# --- Invalid gzip: nonzero + no published output ----------------------------
BAD_GZ="${WORK}/invalid.img.gz"
printf 'this is not a gzip stream\n' > "$BAD_GZ"
BAD_OUT="${WORK}/bad-out"
set +e
bash "$HELPER" "$BAD_GZ" "$BAD_OUT" "$VOL_BYTES"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "helper must reject invalid gzip (got rc=0)"
if [ -e "$BAD_OUT" ]; then
  [ -z "$(ls -A "$BAD_OUT" 2>/dev/null)" ] || fail "invalid gzip must not publish output"
fi
ok "invalid gzip rejected (rc=$rc), no output published"

# --- Existing output dir: refuse + preserve sentinel ------------------------
EXIST_OUT="${WORK}/existing-out"
mkdir -p "$EXIST_OUT"
SENTINEL="${EXIST_OUT}/SENTINEL_DO_NOT_DELETE"
printf 'sentinel\n' > "$SENTINEL"
set +e
bash "$HELPER" "$GZ" "$EXIST_OUT" "$VOL_BYTES"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "helper must refuse an existing output dir"
[ -f "$SENTINEL" ] || fail "helper destroyed the existing output sentinel"
[ "$(cat "$SENTINEL")" = "sentinel" ] || fail "existing output sentinel content changed"
ok "existing output refused (rc=$rc), sentinel preserved"

printf 'PASS: install-7z contract\n'
