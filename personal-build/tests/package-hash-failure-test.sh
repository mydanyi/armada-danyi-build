#!/usr/bin/env bash
# package-hash-failure-test.sh -- RED-first behavioural test for
# personal-build/package-release.sh.
#
# Contract under test:
#   personal-build/package-release.sh TASK_ROOT SRC_ROOT
#       must fail (non-zero) when it cannot compute SHA256 hashes, and a failed
#       run must not publish any TASK_ROOT/output/release/.
#
# The test forces that condition by putting a fake `sha256sum` first on PATH
# that always exits 1, so every hashing attempt fails. package-release.sh is
# EXPECTED TO FAIL RED here (today it publishes a release even though hashing
# failed); it goes GREEN once it refuses to publish on hash failure.
#
# The test runs inside a remote Docker container (as driven by the workflow),
# injects nothing else, needs no network and no real tooling beyond the shell.
# Every fixture lives under the caller's absolute writable $TMPDIR and the trap
# removes only the mktemp directory this test itself created. HOME and
# CODEX_HOME are deliberately neither read nor overwritten.
set -euo pipefail
export LC_ALL=C

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_RELEASE="$TESTS_DIR/../package-release.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

printf '==> package hash-failure regression test\n'

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
TASK="$WORK/task"
SRC="$WORK/src"
FAKEBIN="$WORK/bin"
OUT="$TASK/output"

mkdir -p "$OUT" "$SRC/personal-build" "$FAKEBIN"

# Two small inputs with the names package-release.sh expects, plus the update.sh
# it copies into the release.
head -c 40 /dev/zero | tr '\0' A > "$OUT/armada-$VERSION.img.gz"
head -c 20 /dev/zero | tr '\0' B > "$OUT/armada-$VERSION.oci.tar"
printf '#!/usr/bin/env bash\necho fixture-update\n' > "$SRC/personal-build/update.sh"

# A fake sha256sum that always fails and prints nothing, ahead of the real one.
cat > "$FAKEBIN/sha256sum" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$FAKEBIN/sha256sum"

REL="$OUT/release"

# ---- run package-release.sh with hashing guaranteed to fail -----------------
set +e
( cd -- "$WORK" && \
    PATH="$FAKEBIN:$PATH" \
    ARMADA_VERSION="$VERSION" ARMADA_RELEASE_PART_BYTES=16 \
    bash "$PACKAGE_RELEASE" "$TASK" "$SRC" ) > "$WORK/run.out" 2>&1
rc=$?
set -e

# ---- it must fail and must not leave a release behind -----------------------
(( rc != 0 )) || { fail "package-release returned 0 although sha256sum always failed: $(cat "$WORK/run.out")"; }

if [[ -e "$REL" ]] && [[ -n "$(ls -A "$REL" 2>/dev/null)" ]]; then
    fail "a failed packaging run published a non-empty release/: $REL"
fi

pass 'package-release: hashing failure aborts the run and publishes no release'

printf '\npackage hash-failure test passed\n'
