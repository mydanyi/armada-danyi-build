#!/usr/bin/env bash
# RED-first behavioural regression test for the personal-build upgrade-release
# workflow. It drives two helpers; the parts that are not implemented yet make
# this EXPECTED TO FAIL RED and go GREEN once they satisfy this contract.
#
# Contract under test:
#
#   personal-build/package-release.sh TASK_ROOT SRC_ROOT
#       OUTPUT defaults to TASK_ROOT/output.
#       Inputs already present in $OUTPUT:
#           armada-<VERSION>.img.gz       (VERSION from $ARMADA_VERSION)
#           armada-<VERSION>.oci.tar
#           oci-image-info.json           (skopeo inspect JSON: Architecture
#                                          arm64, Os linux, Digest sha256:<64hex>,
#                                          Labels containers.bootc=1 and
#                                          org.opencontainers.image.version=<VER>)
#       Output into $OUTPUT/release/:
#           - the complete armada-<VERSION>.img.gz stored as-is (never
#             decompressed) inside multi-volume 7z archives
#             armada-<VERSION>.img.gz.7z.001, .7z.002, ... with at most
#             $ARMADA_RELEASE_PART_BYTES bytes per volume (default 1900MiB; the
#             test overrides it to force several volumes).
#           - the OCI archive byte-split into armada-<VERSION>.oci.tar.part000, ...
#           - a verbatim copy of $OUTPUT/oci-image-info.json
#           - a SHA256SUMS listing the complete img.gz, the complete oci.tar,
#             every 7z and OCI volume, the oci-image-info.json copy, plus
#             update.sh / source.tar.gz, with no raw armada-<VERSION>.img entry
#             and no duplicate filename entries.
#       The originals are never modified, the volumes must reassemble
#       byte-for-byte, and a failed run must not publish any release/.
#
#   personal-build/update.sh
#       Default (no flags, or a single [tag]) -- unchanged:
#         queries https://api.github.com/repos/mydanyi/armada-danyi-build/releases/latest
#         (or uses the given tag), downloads that tag's SHA256SUMS + OCI volumes
#         into /var/lib/armada-danyi-updates/<TAG>/, verifies every volume.
#       --check [tag] -- read-only, small metadata only:
#         fetches the Release oci-image-info.json, compares its version/digest
#         with the booted/staged deployment (full `bootc status` JSON,
#         image.version / imageDigest). Prints the pending-or-staged version on
#         stdout and exits 0; when already current prints nothing and exits 7;
#         any error exits 7. It must not download OCI volumes or create a large
#         cache. Normal logs go to stderr.
#       --steam [tag] -- the Steam apply path, inside the original idle:sleep
#         lock: resolves the Release + oci-image-info.json, downloads and
#         verifies the volumes, then deploys via bootc. stdout carries only
#         "N%" progress lines; normal logs go to stderr; any deploy failure is
#         mapped to exit 7. It must never reboot, and must not re-download or
#         re-deploy when the booted or staged deployment already equals the
#         target. The published tag must be "v"+version.
#
# The test runs inside this container (as root for the update half), injects
# fake curl/bootc/uname/systemd-inhibit through PATH, keeps every fixture in
# the caller's $TMPDIR and only removes fixtures it created itself -- including
# its own /var/lib/armada-danyi-updates/<TAG>. No network, no real bootc, no
# reboot. All CPU work runs remotely under Codex.
set -euo pipefail
export LC_ALL=C

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_RELEASE="$TESTS_DIR/../package-release.sh"
UPDATE="$TESTS_DIR/../update.sh"
UPD_ROOT="/var/lib/armada-danyi-updates"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
sha()  { sha256sum -- "$1" | cut -d' ' -f1; }

printf '==> upgrade-release regression test\n'

# ---- RED guard: both targets must exist before any behaviour is exercised ---
red=0
for f in "$PACKAGE_RELEASE" "$UPDATE"; do
    if [[ ! -f "$f" ]]; then
        printf 'RED: target script missing: %s\n' "$f" >&2
        red=1
    fi
done
if (( red )); then
    printf 'RED: personal-build/package-release.sh and personal-build/update.sh are not\n' >&2
    printf 'RED: implemented yet, so upgrade-release behaviour cannot be tested.\n' >&2
    exit 1
fi

# ---- fixtures live under the caller's TMPDIR --------------------------------
: "${TMPDIR:=/tmp}"
[[ "$TMPDIR" == /* && "$TMPDIR" != "/" && -w "$TMPDIR" ]] \
    || fail "TMPDIR must be an absolute writable directory: $TMPDIR"
WORK="$(mktemp -d "$TMPDIR/upgrade-release.XXXXXX")"

INFO_NAME="oci-image-info.json"
RELEASE_TAG="armada-test-20261015"      # default-path release tag (no v-prefix)
NEW_VERSION="20261015.new"              # metadata version for --check / --steam
NEW_TAG="v$NEW_VERSION"                 # Release tag must be "v"+version
OLD_VERSION="20261014.old"
OLD_DIGEST="sha256:$(head -c 64 /dev/zero | tr '\0' 'a')"
NEW_DIGEST="sha256:$(head -c 64 /dev/zero | tr '\0' 'b')"

cleanup() {
    rm -rf -- "$WORK"
    rm -rf -- "$UPD_ROOT/$RELEASE_TAG"
    rm -rf -- "$UPD_ROOT/$NEW_TAG"
    rmdir -- "$UPD_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

mk_blob() {  # mk_blob <path> <size> [char]
    head -c "$2" /dev/zero | tr '\0' "${3:-A}" > "$1"
}

# Write a metadata fixture matching build-oci.sh's skopeo inspect output.
write_image_info() {  # <output-dir> <version> [arch] [os] [bootc] [digest]
    printf '{"Architecture":"%s","Os":"%s","Digest":"%s","Labels":{"containers.bootc":"%s","org.opencontainers.image.version":"%s"}}\n' \
        "${3:-arm64}" "${4:-linux}" "${6:-$NEW_DIGEST}" "${5:-1}" "$2" > "$1/$INFO_NAME"
}

VERSION="$NEW_VERSION"            # --steam metadata must match the OCI filename
IMG_NAME="armada-$VERSION.img.gz"
OCI_NAME="armada-$VERSION.oci.tar"
IMGBASE="armada-$VERSION.img"     # raw image: must never be produced by the build
ARCBASE="$IMG_NAME.7z"            # base name of the split 7z volumes (.7z.001, ...)

# ============================================================================
# Group 1 -- package-release.sh: 7z-split, reassemble, checksums, archive, abort
# ============================================================================
run_package() {  # run_package <task_root> <src_root>
    ( cd -- "$WORK" && ARMADA_VERSION="$VERSION" ARMADA_RELEASE_PART_BYTES=65536 \
        bash "$PACKAGE_RELEASE" "$1" "$2" )
}

PTASK="$WORK/pkg-ok-task"
PSRC="$WORK/pkg-ok-src"
POUT="$PTASK/output"
mkdir -p "$POUT" "$PSRC/personal-build"
# The installer input is a real gzip of a random raw image. Random bytes are
# incompressible, so the .img.gz spans several 7z volumes.
REF_IMG="$WORK/ref.img"
head -c 196608 /dev/urandom > "$REF_IMG"      # ~192KiB raw reference image
gzip -c -- "$REF_IMG" > "$POUT/$IMG_NAME"
mk_blob "$POUT/$OCI_NAME" 81920 B             # 80KiB OCI archive, byte-split
printf '#!/usr/bin/env bash\necho fixture-update\n' > "$PSRC/personal-build/update.sh"
mk_blob "$PSRC/source.tar.gz" 12 S
# The metadata package-release.sh must copy verbatim and hash into SHA256SUMS.
write_image_info "$POUT" "$VERSION" arm64 linux 1 \
    "sha256:$(head -c 64 /dev/zero | tr '\0' 'd')"
img_before="$(sha "$POUT/$IMG_NAME")"
oci_before="$(sha "$POUT/$OCI_NAME")"
info_before="$(sha "$POUT/$INFO_NAME")"

run_package "$PTASK" "$PSRC" >"$WORK/pkg-ok.out" 2>&1 \
    || fail "package-release failed on valid inputs: $(cat "$WORK/pkg-ok.out")"
REL="$POUT/release"
[[ -d "$REL" ]] || fail "package-release did not create $REL"

command -v 7zz >/dev/null || fail "7zz is required for the installer-volume checks"

shopt -s nullglob

# The .img.gz must no longer ship as raw byte splits.
img_parts=( "$REL/$IMG_NAME".part* )
(( ${#img_parts[@]} == 0 )) || fail "release still contains byte-split .img.gz.part volumes"

# ~192KiB .img.gz / 65536-byte volumes -> several volumes, each at most PART_BYTES.
vols=( "$REL/$ARCBASE".[0-9]* )
(( ${#vols[@]} >= 2 )) || fail "expected at least two 7z volumes, found ${#vols[@]}"
[[ "${vols[0]}" == "$REL/$ARCBASE.001" ]] || fail "first 7z volume is not .7z.001: ${vols[0]}"
for v in "${vols[@]}"; do
    sz="$(stat -c %s "$v")"
    (( sz > 0 )) || fail "empty 7z volume: $v"
    (( sz <= 65536 )) || fail "7z volume exceeds PART_BYTES: $v ($sz)"
done

# The first volume alone must recover the exact .img.gz byte-for-byte.
7zz x -so "${vols[0]}" > "$WORK/img.gz.extracted" 2>/dev/null \
    || fail "7zz could not extract the first installer volume"
cmp -s "$WORK/img.gz.extracted" "$POUT/$IMG_NAME" \
    || fail "7z volumes do not recover the original .img.gz byte-for-byte"

# 7zz l: the archive holds only the basename .img.gz, never a raw .img.
arc_entries="$(7zz l -slt -- "${vols[0]}" | awk '/^----------/{seen=1; next} seen && /^Path = /{sub(/^Path = /, ""); print}')"
arc_count="$(printf '%s\n' "$arc_entries" | grep -c . || true)"
(( arc_count == 1 )) || fail "7z archive must hold exactly one entry, found $arc_count"
[[ "$arc_entries" == "$IMG_NAME" ]] || fail "7z archive entry must be $IMG_NAME, found: $arc_entries"

# The OCI archive is still a raw byte split (80KiB -> part000 65536 + part001 16384).
oci_parts=( "$REL/$OCI_NAME".part* )
(( ${#oci_parts[@]} == 2 )) || fail "expected two OCI part volumes, found ${#oci_parts[@]}"
[[ "$(stat -c %s "$REL/$OCI_NAME.part000")" == 65536 ]] || fail "oci part000 size"
[[ "$(stat -c %s "$REL/$OCI_NAME.part001")" == 16384 ]] || fail "oci part001 size"
[[ ! -e "$REL/$OCI_NAME.part002" ]] || fail "oci split produced an extra volume"

# OCI volumes reassemble byte-for-byte and the originals stay untouched.
cat "$REL/$OCI_NAME".part* > "$WORK/oci.reasm"
cmp -s "$WORK/oci.reasm" "$POUT/$OCI_NAME" || fail "oci volumes do not reassemble"
[[ "$(sha "$POUT/$IMG_NAME")" == "$img_before" ]] || fail "package-release modified $IMG_NAME"
[[ "$(sha "$POUT/$OCI_NAME")" == "$oci_before" ]] || fail "package-release modified $OCI_NAME"

# The metadata is copied verbatim into the release.
[[ -f "$REL/$INFO_NAME" ]] || fail "release lacks $INFO_NAME"
cmp -s "$REL/$INFO_NAME" "$POUT/$INFO_NAME" || fail "release rewrote $INFO_NAME"
[[ "$(sha "$POUT/$INFO_NAME")" == "$info_before" ]] || fail "package-release modified $INFO_NAME"

# SHA256SUMS: complete img.gz + oci.tar + metadata and every 7z/OCI volume, with
# no raw image entry and no duplicate filename entries.
SUMS="$REL/SHA256SUMS"
[[ -f "$SUMS" ]] || fail "release is missing SHA256SUMS"
grep -Eq "^$img_before[[:space:]]+$IMG_NAME\$" "$SUMS" || fail "SHA256SUMS lacks the full img.gz hash"
grep -Eq "^$oci_before[[:space:]]+$OCI_NAME\$" "$SUMS" || fail "SHA256SUMS lacks the full oci hash"
grep -Eq "^$info_before[[:space:]]+$INFO_NAME\$" "$SUMS" || fail "SHA256SUMS lacks the $INFO_NAME hash"
IMGBASE_RE="${IMGBASE//./\\.}"
! grep -Eq "([[:space:]]|\*)$IMGBASE_RE\$" "$SUMS" || fail "SHA256SUMS must not list a raw image entry"
mapfile -t sums_names < <(awk '{ n=$NF; sub(/^\*/, "", n); print n }' "$SUMS")
if (( ${#sums_names[@]} > 0 )); then
    dupes="$(printf '%s\n' "${sums_names[@]}" | sort | uniq -d)"
    [[ -z "$dupes" ]] || fail "SHA256SUMS has duplicate filename entries: $dupes"
fi
grep -E '\.7z\.[0-9]+$' "$SUMS" > "$WORK/7z.sums"
[[ "$(wc -l < "$WORK/7z.sums")" -eq "${#vols[@]}" ]] \
    || fail "SHA256SUMS does not list every 7z volume"
grep -E '\.part[0-9]+$' "$SUMS" > "$WORK/oci.sums"
[[ "$(wc -l < "$WORK/oci.sums")" -eq "${#oci_parts[@]}" ]] \
    || fail "SHA256SUMS does not list every OCI volume"
cat "$WORK/7z.sums" "$WORK/oci.sums" > "$WORK/parts.sums"
[[ -s "$WORK/parts.sums" ]] || fail "SHA256SUMS lists no volumes"
( cd "$REL" && sha256sum --check --status "$WORK/parts.sums" ) \
    || fail "SHA256SUMS volume entries do not verify"
( cd "$REL" && printf '%s  %s\n' "$info_before" "$INFO_NAME" | sha256sum --check --status ) \
    || fail "SHA256SUMS metadata entry does not verify"

# update.sh and the source.tar.gz archive are copied into the release.
cmp -s "$REL/update.sh" "$PSRC/personal-build/update.sh" || fail "release lacks update.sh"
if [[ -f "$PSRC/source.tar.gz" ]]; then
    cmp -s "$REL/source.tar.gz" "$PSRC/source.tar.gz" || fail "release lacks source.tar.gz"
fi
pass 'package-release: 7z volumes, OCI split, metadata, SHA256SUMS and archive are correct'

# A failed packaging run must not publish a release.
FTASK="$WORK/pkg-fail-task"
FSRC="$WORK/pkg-fail-src"
FOUT="$FTASK/output"
mkdir -p "$FOUT" "$FSRC/personal-build"
mk_blob "$FOUT/$IMG_NAME" 40 A            # deliberately omit the .oci.tar input
set +e
run_package "$FTASK" "$FSRC" >"$WORK/pkg-fail.out" 2>&1
frc=$?
set -e
[[ "$frc" -ne 0 ]] || fail "package-release succeeded despite a missing input"
if [[ -e "$FOUT/release" ]] && [[ -n "$(ls -A "$FOUT/release" 2>/dev/null)" ]]; then
    fail "failed package-release published a non-empty release/"
fi
pass 'package-release: a failed run publishes no release'

# ============================================================================
# Group 2 -- update.sh: query tag, download + verify volumes, merge, switch,
#            and the --check / --steam Steam entry modes
# ============================================================================
if [[ "${EUID}" -ne 0 ]]; then
    printf 'SKIP: update.sh requires root; run inside the root test container\n'
    printf '\nupgrade-release tests finished (package checks only)\n'
    exit 0
fi

FAKEBIN="$WORK/bin"
FAKECURL="$WORK/curl-src"
mkdir -p "$FAKEBIN" "$FAKECURL"
mkdir -p "$WORK/home/Games"
printf 'precious save data\n' > "$WORK/home/Games/save.dat"

# Fake curl: records the request and serves fixtures by basename, no network.
cat > "$FAKEBIN/curl" <<'CURL'
#!/usr/bin/env bash
log="${FAKE_CURL_LOG:?}"
out=""; url=""
args=("$@")
i=0
while (( i < ${#args[@]} )); do
    a="${args[$i]}"
    case "$a" in
        -o|--output) out="${args[$((i+1))]}"; ((i+=2)); continue ;;
        --output=*)  out="${a#--output=}" ;;
        --*) : ;;
        -*)
            rest="${a#-}"
            if [[ "$rest" == *o ]]; then
                out="${args[$((i+1))]}"; ((i+=2)); continue
            elif [[ "$rest" == *o* ]]; then
                out="${rest#*o}"
            fi ;;
        *) url="$a" ;;
    esac
    ((i+=1))
done
printf '%s\n' "$url" >> "$log"
if [[ "$url" == "https://api.github.com/repos/mydanyi/armada-danyi-build/releases/latest" ]]; then
    body="{\"tag_name\":\"${FAKE_RELEASE_TAG:?}\"}"
    if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
    exit 0
fi
name="${url%%\?*}"; name="${name##*/}"
src="${FAKE_CURL_DIR:?}/$name"
[[ -f "$src" ]] || { printf 'fake-curl: 404 for %s\n' "$url" >&2; exit 22; }
if [[ -n "$out" ]]; then cp -f -- "$src" "$out"; else cat -- "$src"; fi
CURL
chmod +x "$FAKEBIN/curl"

# Fake bootc: records args; `status` emits the configured JSON, `switch`
# succeeds unless told otherwise, nothing else runs.
cat > "$FAKEBIN/bootc" <<'BOOTC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_BOOTC_LOG:?}"
case "${1:-}" in
    status) [[ -n "${FAKE_BOOTC_STATUS_JSON:-}" ]] && cat "$FAKE_BOOTC_STATUS_JSON"; exit "${FAKE_BOOTC_STATUS_RC:-0}" ;;
    switch) exit "${FAKE_BOOTC_SWITCH_RC:-0}" ;;
    *)      exit 0 ;;
esac
BOOTC
chmod +x "$FAKEBIN/bootc"

# Fake uname: report aarch64 for -m, otherwise defer to the real tool.
cat > "$FAKEBIN/uname" <<'UNAME'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then printf '%s\n' "${FAKE_UNAME_M:-aarch64}"; exit 0; fi
if [[ -x /usr/bin/uname ]]; then exec /usr/bin/uname "$@"; fi
exec /bin/uname "$@"
UNAME
chmod +x "$FAKEBIN/uname"

# Minimal systemd-inhibit mock: this container has no system bus, so it parses and
# skips --what/--mode/--who/--why and then runs the wrapped command, returning its
# exit code. It stands in for the CLI only; the lock contract itself is covered by
# tests/update-inhibit-test.sh.
cat > "$FAKEBIN/systemd-inhibit" <<'INHIBIT'
#!/usr/bin/env bash
args=("$@")
i=0
n=${#args[@]}
while (( i < n )); do
    a="${args[$i]}"
    case "$a" in
        --what=*|--mode=*|--who=*|--why=*) : ;;
        --what|--mode|--who|--why) ((i+=1)) ;;
        --list|--version|--help|-h) exit 0 ;;
        --) ((i+=1)); break ;;
        -*) : ;;
        *) break ;;
    esac
    ((i+=1))
done
cmd=("${args[@]:i}")
(( ${#cmd[@]} )) || exit 0
exec "${cmd[@]}"
INHIBIT
chmod +x "$FAKEBIN/systemd-inhibit"

# Record any forbidden reboot path (the script must never call these).
for c in reboot systemctl; do
    cat > "$FAKEBIN/$c" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$c" "\$*" >> "\${FAKE_FORBIDDEN_LOG:?}"
exit 0
EOF
    chmod +x "$FAKEBIN/$c"
done

# Record rm invocations, then perform the real removal.
cat > "$FAKEBIN/rm" <<'RM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_RM_LOG:?}"
if [[ -x /usr/bin/rm ]]; then exec /usr/bin/rm "$@"; fi
exec /bin/rm "$@"
RM
chmod +x "$FAKEBIN/rm"

# bootc status JSON in the shape update.sh parses: the deployment's image.image
# is the real bootc image object {"image":..,"transport":"oci-archive"}, while
# version / imageDigest stay on the outer image node.
write_bootc_status() {  # <booted-version> <booted-digest> [staged-version] [staged-digest]
    local staged="null"
    if [[ -n "${3:-}" ]]; then
        staged="{\"image\":{\"image\":{\"image\":\"ostree-unverified-image:oci-archive:/staged.oci.tar\",\"transport\":\"oci-archive\"},\"imageDigest\":\"${4:-}\",\"version\":\"$3\"}}"
    fi
    cat > "$WORK/bootc-status.json" <<JSON
{"status":{"booted":{"image":{"image":{"image":"ostree-unverified-image:oci-archive:/booted.oci.tar","transport":"oci-archive"},"imageDigest":"$2","version":"$1"}},"staged":$staged,"rollbackQueued":false}}
JSON
}

# Metadata fixture in the release dir (by basename, like the SHA256SUMS).
write_release_image_info() {  # <version> [arch] [os] [bootc] [digest]
    printf '{"Architecture":"%s","Os":"%s","Digest":"%s","Labels":{"containers.bootc":"%s","org.opencontainers.image.version":"%s"}}\n' \
        "${2:-arm64}" "${3:-linux}" "${5:-$NEW_DIGEST}" "${4:-1}" "$1" > "$FAKECURL/$INFO_NAME"
}

prepare_oci_release() {  # <tag assets: SHA256SUMS + OCI volumes + metadata>
    rm -rf -- "$FAKECURL"; mkdir -p "$FAKECURL"
    mk_blob "$WORK/oci.full" 48 A
    FULL_SHA="$(sha "$WORK/oci.full")"
    split -b 16 -d -a 3 -- "$WORK/oci.full" "$FAKECURL/$OCI_NAME.part"
    mk_blob "$WORK/img.full" 32 B
    IMG_SHA="$(sha "$WORK/img.full")"
    write_release_image_info "$NEW_VERSION"
    {
        printf '%s  %s\n' "$IMG_SHA"  "$IMG_NAME"
        printf '%s  %s\n' "$FULL_SHA" "$OCI_NAME"
        printf '%s  %s\n' "$(sha "$FAKECURL/$INFO_NAME")" "$INFO_NAME"
        local p
        for p in "$FAKECURL/$OCI_NAME.part"*; do
            printf '%s  %s\n' "$(sha "$p")" "$(basename "$p")"
        done
    } > "$FAKECURL/SHA256SUMS"
}

# run_update <label> [update.sh args...]
# Uses globals: FAKECURL, FAKE_RELEASE_TAG, optional FAKE_BOOTC_SWITCH_RC, and
# optional UPDATE_SCRIPT (defaults to the real personal-build/update.sh; the
# personal-channel scenario points it at a path-rewritten copy inside $WORK).
run_update() {
    local label="$1"; shift
    : > "$WORK/bootc.log"; : > "$WORK/curl.log"
    : > "$WORK/forbidden.log"; : > "$WORK/rm.log"
    rm -rf -- "$UPD_ROOT/$RELEASE_TAG" "$UPD_ROOT/$NEW_TAG"
    set +e
    env \
        PATH="$FAKEBIN:/usr/bin:/bin" \
        FAKE_CURL_LOG="$WORK/curl.log" \
        FAKE_CURL_DIR="$FAKECURL" \
        FAKE_RELEASE_TAG="$FAKE_RELEASE_TAG" \
        FAKE_BOOTC_LOG="$WORK/bootc.log" \
        FAKE_BOOTC_STATUS_JSON="$WORK/bootc-status.json" \
        FAKE_BOOTC_SWITCH_RC="${FAKE_BOOTC_SWITCH_RC:-0}" \
        FAKE_FORBIDDEN_LOG="$WORK/forbidden.log" \
        FAKE_RM_LOG="$WORK/rm.log" \
        FAKE_UNAME_M=aarch64 \
        bash "${UPDATE_SCRIPT:-$UPDATE}" "$@" >"$WORK/$label.out" 2>"$WORK/$label.err"
    update_rc=$?
    set -e
}

FAKE_RELEASE_TAG="$RELEASE_TAG"
FAKE_BOOTC_SWITCH_RC=0
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""

# --- Scenario 1: full volumes verified, OCI staged, no reboot ----------------
prepare_oci_release
run_update success
[[ "$update_rc" -eq 0 ]] || fail "update.sh failed on a valid release: $(cat "$WORK/success.out" "$WORK/success.err")"

grep -qx 'https://api.github.com/repos/mydanyi/armada-danyi-build/releases/latest' "$WORK/curl.log" \
    || fail "update.sh did not query the default releases/latest endpoint"

MERGED="$UPD_ROOT/$RELEASE_TAG/$OCI_NAME"
[[ -f "$MERGED" ]] || fail "update.sh did not stage the merged OCI at $MERGED"
[[ "$(sha "$MERGED")" == "$FULL_SHA" ]] || fail "merged OCI does not match the published package"

grep -q '^status' "$WORK/bootc.log" || fail "update.sh did not run 'bootc status'"
[[ "$(grep -c '^switch' "$WORK/bootc.log")" -eq 1 ]] || fail "expected exactly one bootc switch"
grep -q -- '--transport oci-archive' "$WORK/bootc.log" \
    || fail "bootc switch did not use --transport oci-archive"
grep -qF -- "$MERGED" "$WORK/bootc.log" \
    || fail "bootc switch did not name the merged OCI archive"
if grep -q -- '--apply' "$WORK/bootc.log"; then fail "update.sh invoked bootc --apply"; fi

! grep -Eq '^reboot( |$)' "$WORK/forbidden.log" || fail "update.sh called reboot"
! grep -Eq '^systemctl +reboot' "$WORK/forbidden.log" || fail "update.sh called systemctl reboot"

[[ -f "$WORK/home/Games/save.dat" ]] || fail "update.sh deleted user data under HOME"
! grep -Fq -- "$WORK/home" "$WORK/rm.log" || fail "update.sh removed something under HOME"
pass 'update.sh: volumes verified, OCI merged, staged via bootc switch, no reboot'

# --- Scenario 2: a tampered volume is rejected before bootc switch -----------
prepare_oci_release
printf 'X' | dd of="$FAKECURL/$OCI_NAME.part000" bs=1 seek=0 conv=notrunc status=none
run_update tampered
[[ "$update_rc" -ne 0 ]] || fail "update.sh accepted a tampered volume: $(cat "$WORK/tampered.out" "$WORK/tampered.err")"
! grep -q '^switch' "$WORK/bootc.log" || fail "bootc switch ran despite a tampered volume"
pass 'update.sh: a tampered volume is rejected before bootc switch'

# --- Scenario 3: a failed volume download is rejected before bootc switch ----
prepare_oci_release
rm -f -- "$FAKECURL/$OCI_NAME.part001"
run_update missing
[[ "$update_rc" -ne 0 ]] || fail "update.sh accepted a missing volume: $(cat "$WORK/missing.out" "$WORK/missing.err")"
! grep -q '^switch' "$WORK/bootc.log" || fail "bootc switch ran despite a missing volume"
pass 'update.sh: a failed volume download is rejected before bootc switch'

# --- Scenario 4: --check reports a pending version without downloading ANY part
write_release_image_info "$NEW_VERSION"
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""
FAKE_RELEASE_TAG="$NEW_TAG"
run_update check_pending --check
[[ "$update_rc" -eq 0 ]] || fail "--check returned $update_rc for a pending update: $(cat "$WORK/check_pending.out" "$WORK/check_pending.err")"
[[ "$(cat "$WORK/check_pending.out")" == "$NEW_VERSION" ]] \
    || fail "--check stdout '$(cat "$WORK/check_pending.out")' != '$NEW_VERSION'"
grep -q "$NEW_TAG/$INFO_NAME" "$WORK/curl.log" \
    || fail "--check did not fetch the release oci-image-info.json"
! grep -q '\.part' "$WORK/curl.log" || fail "--check downloaded OCI volumes"
if [[ -d "$UPD_ROOT/$NEW_TAG" ]]; then
    compgen -G "$UPD_ROOT/$NEW_TAG/*.part[0-9]*" >/dev/null && fail "--check cached OCI volumes"
    compgen -G "$UPD_ROOT/$NEW_TAG/*.oci.tar" >/dev/null && fail "--check cached the OCI archive"
fi
pass 'update.sh --check: pending version printed, no volumes, exit 0'

# --- Scenario 5: --check is silent with exit 7 when already current ----------
write_bootc_status "$NEW_VERSION" "$NEW_DIGEST" ""
run_update check_latest --check
[[ "$update_rc" -eq 7 ]] || fail "--check returned $update_rc when already current"
[[ -z "$(cat "$WORK/check_latest.out")" ]] || fail "--check printed on the up-to-date path: $(cat "$WORK/check_latest.out")"
pass 'update.sh --check: already current -> no stdout, exit 7'

# --- Scenario 6: --check reports a staged target (restart pending) -----------
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" "$NEW_VERSION" "$NEW_DIGEST"
run_update check_staged --check
[[ "$update_rc" -eq 0 ]] || fail "--check returned $update_rc for a staged target"
[[ "$(cat "$WORK/check_staged.out")" == "$NEW_VERSION" ]] \
    || fail "--check did not report the staged version"
pass 'update.sh --check: staged target reported, exit 0'

# --- Scenario 7: --check rejects missing / mismatched metadata ---------------
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""
rm -f -- "$FAKECURL/$INFO_NAME"
run_update check_missing --check
[[ "$update_rc" -eq 7 ]] || fail "--check returned $update_rc with missing metadata"
[[ -z "$(cat "$WORK/check_missing.out")" ]] || fail "--check printed with missing metadata"
write_release_image_info "99999999.bad"
run_update check_mismatch --check
[[ "$update_rc" -eq 7 ]] || fail "--check accepted a tag/metadata version mismatch"
pass 'update.sh --check: invalid metadata -> exit 7'

# --- Scenario 8: --steam applies: stdout is only N%, logs on stderr ----------
prepare_oci_release
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""
run_update steam_ok --steam
[[ "$update_rc" -eq 0 ]] || fail "--steam failed on a valid release: $(cat "$WORK/steam_ok.err")"
[[ -s "$WORK/steam_ok.out" ]] || fail "--steam printed no progress on stdout"
if grep -vqE '^[0-9]+%$' "$WORK/steam_ok.out"; then
    fail "--steam stdout carried non-progress lines: $(cat "$WORK/steam_ok.out")"
fi
[[ -s "$WORK/steam_ok.err" ]] || fail "--steam logged nothing to stderr"
[[ "$(grep -c '^switch' "$WORK/bootc.log")" -eq 1 ]] || fail "--steam did not call bootc switch exactly once"
switch_line="$(grep '^switch' "$WORK/bootc.log")"
switch_path="${switch_line##* }"
[[ -f "$switch_path" ]] || fail "--steam bootc switch did not name a staged archive: $switch_line"
[[ "$(sha "$switch_path")" == "$FULL_SHA" ]] || fail "--steam staged a corrupted OCI archive"
! grep -Eq '^reboot( |$)' "$WORK/forbidden.log" || fail "--steam called reboot"
! grep -Eq '^systemctl +reboot' "$WORK/forbidden.log" || fail "--steam called systemctl reboot"
pass 'update.sh --steam: progress on stdout, logs on stderr, bootc switch, no reboot'

# --- Scenario 9: --steam rejects a tampered volume before deploying ---------
prepare_oci_release
printf 'X' | dd of="$FAKECURL/$OCI_NAME.part000" bs=1 seek=0 conv=notrunc status=none
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""
run_update steam_tampered --steam
[[ "$update_rc" -eq 7 ]] || fail "--steam returned $update_rc for a tampered volume"
! grep -q '^switch' "$WORK/bootc.log" || fail "--steam switched despite a tampered volume"
pass 'update.sh --steam: a tampered volume is rejected (exit 7) before bootc switch'

# --- Scenario 10: --steam maps a deploy failure to exit 7, no reboot --------
prepare_oci_release
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""
FAKE_BOOTC_SWITCH_RC=1 run_update steam_fail --steam
FAKE_BOOTC_SWITCH_RC=0
[[ "$update_rc" -eq 7 ]] || fail "--steam returned $update_rc when bootc switch failed: $(cat "$WORK/steam_fail.err")"
! grep -Eq '^reboot( |$)' "$WORK/forbidden.log" || fail "--steam rebooted after a failed deploy"
pass 'update.sh --steam: a deploy failure maps to exit 7 without reboot'

# --- Scenario 11: --steam does not re-download / re-deploy a current target --
prepare_oci_release
write_bootc_status "$NEW_VERSION" "$NEW_DIGEST" ""
run_update steam_current --steam
[[ "$update_rc" -eq 0 ]] || fail "--steam returned $update_rc when already current"
! grep -q '\.part' "$WORK/curl.log" || fail "--steam re-downloaded volumes when already current"
! grep -q '^switch' "$WORK/bootc.log" || fail "--steam re-deployed an already-current target"
# A successful no-op must still terminate the progress stream at 100%.
[[ "$(tail -n1 "$WORK/steam_current.out")" == "100%" ]] \
    || fail "--steam did not end an already-current no-op with 100%: $(cat "$WORK/steam_current.out")"
pass 'update.sh --steam: an already-current target is neither re-downloaded nor re-deployed'

# --- Scenario 12 (gap A): --check maps a structurally-wrong metadata JSON to
#     the Steam exit 7, with empty stdout and no side effects ------------------
# A top-level array instead of an object, and a string Labels instead of an
# object, both make the jq field extraction fail. That jq type error must be
# normalised to exit 7 -- never leaked as jq's own exit code -- and must not
# download OCI volumes nor call bootc switch.
prepare_oci_release
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""
FAKE_RELEASE_TAG="$NEW_TAG"

printf '[]\n' > "$FAKECURL/$INFO_NAME"
run_update check_top_array --check
[[ "$update_rc" -eq 7 ]] || fail "--check returned $update_rc (not 7) for top-level-array metadata: $(cat "$WORK/check_top_array.err")"
[[ -z "$(cat "$WORK/check_top_array.out")" ]] || fail "--check wrote stdout for top-level-array metadata"
! grep -q '\.part' "$WORK/curl.log" || fail "--check downloaded OCI volumes for top-level-array metadata"
! grep -q '^switch' "$WORK/bootc.log" || fail "--check switched for top-level-array metadata"

printf '{"Architecture":"arm64","Os":"linux","Digest":"%s","Labels":"not-an-object"}\n' "$NEW_DIGEST" > "$FAKECURL/$INFO_NAME"
run_update check_labels_string --check
[[ "$update_rc" -eq 7 ]] || fail "--check returned $update_rc (not 7) for string-Labels metadata: $(cat "$WORK/check_labels_string.err")"
[[ -z "$(cat "$WORK/check_labels_string.out")" ]] || fail "--check wrote stdout for string-Labels metadata"
! grep -q '\.part' "$WORK/curl.log" || fail "--check downloaded OCI volumes for string-Labels metadata"
! grep -q '^switch' "$WORK/bootc.log" || fail "--check switched for string-Labels metadata"

prepare_oci_release   # restore a well-formed metadata fixture
pass 'update.sh --check: malformed metadata JSON (array / string Labels) -> exit 7, no side effects'

# --- Scenario 13 (gap B): --check matches a staged target by digest alone -----
# bootc status may omit the optional staged image.version. The CLI must still
# recognise the staged deployment through its imageDigest and print the target
# version -- not an empty line (the actual Steam protocol regression).
prepare_oci_release
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" "$NEW_VERSION" "$NEW_DIGEST"
jq '.status.staged.image.version = null' "$WORK/bootc-status.json" > "$WORK/bootc-status.tmp" \
    && mv "$WORK/bootc-status.tmp" "$WORK/bootc-status.json"
FAKE_RELEASE_TAG="$NEW_TAG"
run_update check_staged_digest --check
[[ "$update_rc" -eq 0 ]] || fail "--check returned $update_rc for a digest-only staged target: $(cat "$WORK/check_staged_digest.err")"
[[ "$(cat "$WORK/check_staged_digest.out")" == "$NEW_VERSION" ]] \
    || fail "--check printed '$(cat "$WORK/check_staged_digest.out")' instead of '$NEW_VERSION' for a version-less staged target"
pass 'update.sh --check: staged target matched by digest, version (not an empty line) printed'

# --- Scenario 14 (gap C): --steam no-op on a staged target ends at 100% -------
# Same progress contract as Scenario 11, for the staged path: no re-download,
# no re-deploy, stdout only "N%" and the final line exactly 100%.
prepare_oci_release
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" "$NEW_VERSION" "$NEW_DIGEST"
run_update steam_staged --steam
[[ "$update_rc" -eq 0 ]] || fail "--steam returned $update_rc for a staged target: $(cat "$WORK/steam_staged.err")"
! grep -q '\.part' "$WORK/curl.log" || fail "--steam re-downloaded volumes for a staged target"
! grep -q '^switch' "$WORK/bootc.log" || fail "--steam re-deployed a staged target"
[[ -s "$WORK/steam_staged.out" ]] || fail "--steam printed no progress for a staged target"
if grep -vqE '^[0-9]+%$' "$WORK/steam_staged.out"; then
    fail "--steam stdout carried non-progress lines for a staged target: $(cat "$WORK/steam_staged.out")"
fi
[[ "$(tail -n1 "$WORK/steam_staged.out")" == "100%" ]] \
    || fail "--steam did not end a staged no-op with 100%: $(cat "$WORK/steam_staged.out")"
pass 'update.sh --steam: a staged no-op is not re-downloaded/re-deployed and ends at 100%'

# --- Scenario 15 (gap D): default CLI restores the personal update channel ----
# Switching back from an official system to the single-wing build must rewrite
# the personal channel selection file to 'danyi', so the next boot no longer
# points at the official stable/beta channel; a failed switch must leave the
# previous choice untouched. The real /var/lib/armada/personal-update-channel is
# never touched: update.sh is copied into $WORK and only that absolute state path
# is redirected there, reusing the existing fake boundaries/cache.
PCHAN_STATE="$WORK/personal-channel-state"
PCHAN_SCRIPT="$WORK/update-personal-channel.sh"
sed "s#/var/lib/armada/personal-update-channel#$PCHAN_STATE#g" "$UPDATE" > "$PCHAN_SCRIPT"
UPDATE_SCRIPT="$PCHAN_SCRIPT"

prepare_oci_release
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""
FAKE_RELEASE_TAG="$RELEASE_TAG"
printf 'stable\n' > "$PCHAN_STATE"
FAKE_BOOTC_SWITCH_RC=0 run_update personal_channel_ok
[[ "$update_rc" -eq 0 ]] || fail "default CLI failed with the personal-channel copy: $(cat "$WORK/personal_channel_ok.err")"
[[ "$(cat "$PCHAN_STATE")" == "danyi" ]] \
    || fail "default CLI did not restore the personal channel to danyi after a successful switch: '$(cat "$PCHAN_STATE")'"

prepare_oci_release
write_bootc_status "$OLD_VERSION" "$OLD_DIGEST" ""
printf 'stable\n' > "$PCHAN_STATE"
FAKE_BOOTC_SWITCH_RC=1 run_update personal_channel_fail
FAKE_BOOTC_SWITCH_RC=0
[[ "$update_rc" -ne 0 ]] || fail "default CLI reported success despite a failed bootc switch"
[[ "$(cat "$PCHAN_STATE")" == "stable" ]] \
    || fail "default CLI overwrote the personal channel despite a failed switch: '$(cat "$PCHAN_STATE")'"

unset UPDATE_SCRIPT
pass 'update.sh: default CLI restores the personal channel to danyi only on a successful switch'

printf '\nupgrade-release tests passed\n'
