#!/usr/bin/env bash
# RED-first behavioural regression test for the personal-build upgrade-release
# workflow. It drives two helpers that are not implemented yet, so today it is
# EXPECTED TO FAIL RED and go GREEN once they satisfy this contract.
#
# Contract under test (fixed interface):
#
#   personal-build/package-release.sh TASK_ROOT SRC_ROOT
#       OUTPUT defaults to TASK_ROOT/output.
#       Inputs already present in $OUTPUT:
#           armada-<VERSION>.img.gz
#           armada-<VERSION>.oci.tar      (VERSION from $ARMADA_VERSION)
#       Output into $OUTPUT/release/:
#           - every big input split into <full-name>.part000, .part001, ...
#             with $ARMADA_RELEASE_PART_BYTES bytes per volume (default 1900MiB;
#             the test overrides it to force several volumes)
#           - a SHA256SUMS listing the complete packages AND every volume
#           - a copy of update.sh and of the source.tar.gz source archive
#             (the source archive is optional when its fixture is absent; this
#             test does create the fixture and therefore expects the copy)
#       The originals are never modified, the volumes must reassemble
#       byte-for-byte, and a failed run must not publish any release/.
#
#   personal-build/update.sh
#       Queries https://api.github.com/repos/mydanyi/armada-danyi-build/releases/latest
#       for tag_name, downloads that tag's SHA256SUMS plus its OCI volumes into
#       /var/lib/armada-danyi-updates/<TAG>/, verifies every volume, merges the
#       OCI archive, verifies the merged package, then runs
#       `bootc switch --transport oci-archive <PATH>`. It requires root and
#       `uname -m` == aarch64 and a working `bootc status`. It must NEVER call
#       reboot / systemctl reboot / bootc --apply and must not delete user data
#       such as games directories.
#
# The test runs inside this container (as root for the update half), injects
# fake curl/bootc/uname/reboot/systemctl through PATH, keeps every fixture in
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
RELEASE_TAG="armada-test-20261015"
cleanup() {
    rm -rf -- "$WORK"
    rm -rf -- "$UPD_ROOT/$RELEASE_TAG"
    rmdir -- "$UPD_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

mk_blob() {  # mk_blob <path> <size> [char]
    head -c "$2" /dev/zero | tr '\0' "${3:-A}" > "$1"
}

VERSION="20261015.abcd1234"
IMG_NAME="armada-$VERSION.img.gz"
OCI_NAME="armada-$VERSION.oci.tar"

# ============================================================================
# Group 1 -- package-release.sh: split, reassemble, checksums, archive, abort
# ============================================================================
run_package() {  # run_package <task_root> <src_root>
    ( cd -- "$WORK" && ARMADA_VERSION="$VERSION" ARMADA_RELEASE_PART_BYTES=16 \
        bash "$PACKAGE_RELEASE" "$1" "$2" )
}

PTASK="$WORK/pkg-ok-task"
PSRC="$WORK/pkg-ok-src"
POUT="$PTASK/output"
mkdir -p "$POUT" "$PSRC/personal-build"
mk_blob "$POUT/$IMG_NAME" 40 A
mk_blob "$POUT/$OCI_NAME" 20 B
printf '#!/usr/bin/env bash\necho fixture-update\n' > "$PSRC/personal-build/update.sh"
mk_blob "$PSRC/source.tar.gz" 12 S
img_before="$(sha "$POUT/$IMG_NAME")"
oci_before="$(sha "$POUT/$OCI_NAME")"

run_package "$PTASK" "$PSRC" >"$WORK/pkg-ok.out" 2>&1 \
    || fail "package-release failed on valid inputs: $(cat "$WORK/pkg-ok.out")"
REL="$POUT/release"
[[ -d "$REL" ]] || fail "package-release did not create $REL"

# 40-byte input / 16-byte volumes -> part000..part002 (16,16,8);
# 20-byte input / 16-byte volumes -> part000..part001 (16,4).
[[ "$(stat -c %s "$REL/$IMG_NAME.part000")" == 16 ]] || fail "img part000 size"
[[ "$(stat -c %s "$REL/$IMG_NAME.part001")" == 16 ]] || fail "img part001 size"
[[ "$(stat -c %s "$REL/$IMG_NAME.part002")" == 8  ]] || fail "img part002 size"
[[ ! -e "$REL/$IMG_NAME.part003" ]] || fail "img split produced an extra volume"
[[ "$(stat -c %s "$REL/$OCI_NAME.part000")" == 16 ]] || fail "oci part000 size"
[[ "$(stat -c %s "$REL/$OCI_NAME.part001")" == 4  ]] || fail "oci part001 size"
[[ ! -e "$REL/$OCI_NAME.part002" ]] || fail "oci split produced an extra volume"

# Volumes reassemble byte-for-byte and the originals stay untouched.
cat "$REL/$IMG_NAME".part* > "$WORK/img.reasm"
cat "$REL/$OCI_NAME".part* > "$WORK/oci.reasm"
cmp -s "$WORK/img.reasm" "$POUT/$IMG_NAME" || fail "img volumes do not reassemble"
cmp -s "$WORK/oci.reasm" "$POUT/$OCI_NAME" || fail "oci volumes do not reassemble"
[[ "$(sha "$POUT/$IMG_NAME")" == "$img_before" ]] || fail "package-release modified $IMG_NAME"
[[ "$(sha "$POUT/$OCI_NAME")" == "$oci_before" ]] || fail "package-release modified $OCI_NAME"

# SHA256SUMS: complete-package hashes match the originals; volume lines verify.
SUMS="$REL/SHA256SUMS"
[[ -f "$SUMS" ]] || fail "release is missing SHA256SUMS"
grep -Eq "^$img_before[[:space:]]+$IMG_NAME\$" "$SUMS" || fail "SHA256SUMS lacks the full img hash"
grep -Eq "^$oci_before[[:space:]]+$OCI_NAME\$" "$SUMS" || fail "SHA256SUMS lacks the full oci hash"
grep -E '\.part[0-9]+$' "$SUMS" > "$WORK/parts.sums"
[[ -s "$WORK/parts.sums" ]] || fail "SHA256SUMS lists no volumes"
( cd "$REL" && sha256sum --check --status "$WORK/parts.sums" ) \
    || fail "SHA256SUMS volume entries do not verify"

# update.sh and the source.tar.gz archive are copied into the release.
cmp -s "$REL/update.sh" "$PSRC/personal-build/update.sh" || fail "release lacks update.sh"
if [[ -f "$PSRC/source.tar.gz" ]]; then
    cmp -s "$REL/source.tar.gz" "$PSRC/source.tar.gz" || fail "release lacks source.tar.gz"
fi
pass 'package-release: volumes, reassembly, SHA256SUMS and archive are correct'

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
# Group 2 -- update.sh: query tag, download + verify volumes, merge, switch
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

# Fake bootc: records args; status and switch succeed, nothing else runs.
cat > "$FAKEBIN/bootc" <<'BOOTC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_BOOTC_LOG:?}"
case "${1:-}" in
    status) exit "${FAKE_BOOTC_STATUS_RC:-0}" ;;
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

prepare_oci_release() {  # <tag> assets: SHA256SUMS + OCI volumes
    rm -rf -- "$FAKECURL"; mkdir -p "$FAKECURL"
    mk_blob "$WORK/oci.full" 48 A
    FULL_SHA="$(sha "$WORK/oci.full")"
    split -b 16 -d -a 3 -- "$WORK/oci.full" "$FAKECURL/$OCI_NAME.part"
    mk_blob "$WORK/img.full" 32 B
    IMG_SHA="$(sha "$WORK/img.full")"
    {
        printf '%s  %s\n' "$IMG_SHA"  "$IMG_NAME"
        printf '%s  %s\n' "$FULL_SHA" "$OCI_NAME"
        local p
        for p in "$FAKECURL/$OCI_NAME.part"*; do
            printf '%s  %s\n' "$(sha "$p")" "$(basename "$p")"
        done
    } > "$FAKECURL/SHA256SUMS"
}

run_update() {  # run_update <label>
    local label="$1"
    : > "$WORK/bootc.log"; : > "$WORK/curl.log"
    : > "$WORK/forbidden.log"; : > "$WORK/rm.log"
    rm -rf -- "$UPD_ROOT/$RELEASE_TAG"
    set +e
    env \
        PATH="$FAKEBIN:/usr/bin:/bin" \
        FAKE_CURL_LOG="$WORK/curl.log" \
        FAKE_CURL_DIR="$FAKECURL" \
        FAKE_RELEASE_TAG="$RELEASE_TAG" \
        FAKE_BOOTC_LOG="$WORK/bootc.log" \
        FAKE_FORBIDDEN_LOG="$WORK/forbidden.log" \
        FAKE_RM_LOG="$WORK/rm.log" \
        FAKE_UNAME_M=aarch64 \
        bash "$UPDATE" >"$WORK/$label.out" 2>&1
    update_rc=$?
    set -e
}

# --- Scenario 1: full volumes verified, OCI staged, no reboot ----------------
prepare_oci_release
run_update success
[[ "$update_rc" -eq 0 ]] || fail "update.sh failed on a valid release: $(cat "$WORK/success.out")"

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
[[ "$update_rc" -ne 0 ]] || fail "update.sh accepted a tampered volume: $(cat "$WORK/tampered.out")"
! grep -q '^switch' "$WORK/bootc.log" || fail "bootc switch ran despite a tampered volume"
pass 'update.sh: a tampered volume is rejected before bootc switch'

# --- Scenario 3: a failed volume download is rejected before bootc switch ----
prepare_oci_release
rm -f -- "$FAKECURL/$OCI_NAME.part001"
run_update missing
[[ "$update_rc" -ne 0 ]] || fail "update.sh accepted a missing volume: $(cat "$WORK/missing.out")"
! grep -q '^switch' "$WORK/bootc.log" || fail "bootc switch ran despite a missing volume"
pass 'update.sh: a failed volume download is rejected before bootc switch'

printf '\nupgrade-release tests passed\n'
