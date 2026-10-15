#!/usr/bin/env bash
# package-hash-failure-test.sh -- RED-first behavioural test for
# personal-build/package-release.sh metadata validation and abort behaviour.
#
# Contract under test:
#   personal-build/package-release.sh TASK_ROOT SRC_ROOT must refuse to publish
#   (non-zero, no TASK_ROOT/output/release/) when:
#     * SHA256 hashing cannot be computed (fake sha256sum always fails), or
#     * the required TASK_ROOT/output/oci-image-info.json is missing, or
#     * that metadata is malformed (bad hash) or its version disagrees with
#       ARMADA_VERSION.
#   On success the metadata is copied into the release and listed in
#   SHA256SUMS, but this focused test only exercises the failure paths.
#
# The test runs inside a remote Docker container, injects only the fake
# sha256sum, needs no network and no real tooling beyond the shell. Every
# fixture lives under the caller's absolute writable $TMPDIR and the trap
# removes only the mktemp directory this test itself created. HOME and
# CODEX_HOME are deliberately neither read nor overwritten.
set -euo pipefail
export LC_ALL=C

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_RELEASE="$TESTS_DIR/../package-release.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

printf '==> package metadata/hash-failure regression test\n'

# ---- target must exist before any behaviour is exercised --------------------
if [[ ! -f "$PACKAGE_RELEASE" ]]; then
    printf 'RED: target script missing: %s\n' "$PACKAGE_RELEASE" >&2
    printf 'RED: personal-build/package-release.sh is not implemented yet.\n' >&2
    exit 1
fi

# ---- fixtures live under the caller's TMPDIR --------------------------------
: "${TMPDIR:=/tmp}"
[[ "$TMPDIR" == /* && "$TMPDIR" != "/" && -w "$TMPDIR" ]] \
    || fail "TMPDIR must be an absolute writable directory: $TMPDIR"

WORK="$(mktemp -d "$TMPDIR/package-hash-failure.XXXXXX")"
# Only remove the mktemp directory THIS test created.
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

VERSION="TEST"
FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"

# A fake sha256sum that always fails and prints nothing, ahead of the real one.
cat > "$FAKEBIN/sha256sum" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$FAKEBIN/sha256sum"

DIGEST="sha256:$(head -c 64 /dev/zero | tr '\0' 'c')"

# setup_case <dir>: the inputs package-release.sh expects, minus the metadata.
setup_case() {
    local dir="$1"
    mkdir -p "$dir/output" "$dir/src/personal-build"
    head -c 64 /dev/urandom > "$dir/raw.img"
    gzip -c -- "$dir/raw.img" > "$dir/output/armada-$VERSION.img.gz"
    head -c 20 /dev/zero | tr '\0' B > "$dir/output/armada-$VERSION.oci.tar"
    printf '#!/usr/bin/env bash\necho fixture-update\n' > "$dir/src/personal-build/update.sh"
}

# write_info <output-dir> <version> [arch] [os] [bootc] [digest]
write_info() {
    printf '{"Architecture":"%s","Os":"%s","Digest":"%s","Labels":{"containers.bootc":"%s","org.opencontainers.image.version":"%s"}}\n' \
        "${3:-arm64}" "${4:-linux}" "${6:-$DIGEST}" "${5:-1}" "$2" > "$1/oci-image-info.json"
}

# run_package <dir> [PATH-prefix]
run_package() {
    local dir="$1" prefix="${2:-}" path="$PATH"
    [[ -n "$prefix" ]] && path="$prefix:$PATH"
    set +e
    ( cd -- "$WORK" && \
        env PATH="$path" ARMADA_VERSION="$VERSION" ARMADA_RELEASE_PART_BYTES=16 \
        bash "$PACKAGE_RELEASE" "$dir" "$dir/src" ) > "$dir/run.out" 2>&1
    local rc=$?
    set -e
    return "$rc"
}

assert_aborted() {  # assert_aborted <dir> <label>
    local dir="$1" label="$2" rel="$1/output/release"
    if [[ -e "$rel" ]] && [[ -n "$(ls -A "$rel" 2>/dev/null)" ]]; then
        fail "$label published a non-empty release/: $rel"
    fi
}

# ---- Case A: SHA256 hashing fails -------------------------------------------
CA="$WORK/hash-fail"
setup_case "$CA"; write_info "$CA/output" "$VERSION"
rc=0; run_package "$CA" "$FAKEBIN" || rc=$?
(( rc != 0 )) || fail "package-release returned 0 although sha256sum always failed: $(cat "$CA/run.out")"
assert_aborted "$CA" "hashing failure"
pass 'package-release: hashing failure aborts and publishes no release'

# ---- Case B: metadata missing ------------------------------------------------
CB="$WORK/no-info"
setup_case "$CB"                      # deliberately no oci-image-info.json
rc=0; run_package "$CB" || rc=$?
(( rc != 0 )) || fail "package-release accepted a release with no oci-image-info.json: $(cat "$CB/run.out")"
assert_aborted "$CB" "missing metadata"
pass 'package-release: missing oci-image-info.json is refused'

# ---- Case C: metadata version disagrees with ARMADA_VERSION ------------------
CC="$WORK/version-mismatch"
setup_case "$CC"; write_info "$CC/output" "OTHER"
rc=0; run_package "$CC" || rc=$?
(( rc != 0 )) || fail "package-release accepted a metadata version mismatch: $(cat "$CC/run.out")"
assert_aborted "$CC" "version mismatch"
pass 'package-release: metadata version mismatch is refused'

# ---- Case D: malformed metadata (bad digest / arch) --------------------------
for bad in digest arch; do
    CD="$WORK/bad-$bad"
    setup_case "$CD"
    if [[ "$bad" == digest ]]; then
        write_info "$CD/output" "$VERSION" arm64 linux 1 "sha256:not-a-real-hash"
    else
        write_info "$CD/output" "$VERSION" amd64 linux 1
    fi
    rc=0; run_package "$CD" || rc=$?
    (( rc != 0 )) || fail "package-release accepted $bad metadata: $(cat "$CD/run.out")"
    assert_aborted "$CD" "malformed $bad metadata"
    pass "package-release: malformed $bad metadata is refused"
done

printf '\npackage metadata/hash-failure test passed\n'
