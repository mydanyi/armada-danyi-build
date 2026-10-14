#!/usr/bin/env bash
# Behavioral test for armada_update_target (personal-build update target selection).
# Expected to be RED until the production implementation stops auto-following
# the official beta and stops accepting non-personal OCI refs without a marker.
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

MARKER="/usr/share/armada/personal-build/plugins.lock.json"
OFFICIAL_REF="ostree-unverified-registry:ghcr.io/armada-os/armada:beta"
OFFICIAL_EXPECT="ghcr.io/armada-os/armada beta"
LOCAL_REF="ostree-unverified-image:oci-archive:/var/lib/armada-danyi-updates/test/test.oci.tar"

MARKER_CREATED=0

# Only remove the marker if THIS test created it.
cleanup() {
  if [ "$MARKER_CREATED" -eq 1 ]; then
    rm -f "$MARKER"
  fi
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

# shellcheck source=/dev/null
. "$SRC_ROOT/system_files/usr/lib/armada/update-lib" || fail "cannot source update-lib from $SRC_ROOT"

# 1) Fresh container must not have the personal-build marker.
if [ -e "$MARKER" ]; then
  fail "marker unexpectedly present before test: $MARKER"
fi
pass "marker absent at start"

# 2) With no marker, the official beta ref resolves to its canonical name.
out="$(armada_update_target "$OFFICIAL_REF")"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "official ref returned non-zero ($rc) with no marker"
fi
if [ "$out" != "$OFFICIAL_EXPECT" ]; then
  fail "official ref returned '$out', expected '$OFFICIAL_EXPECT'"
fi
pass "official beta resolves to '$OFFICIAL_EXPECT'"

# 3) Local OCI ref must be honored; never fall back to official.
out="$(armada_update_target "$LOCAL_REF")"
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "local OCI ref returned 0 (fell back to official?): '$out'"
fi
pass "local OCI ref rejected without fallback (rc=$rc)"

# 4) With the personal marker present, official ref must NOT auto-follow.
mkdir -p "$(dirname "$MARKER")"
: > "$MARKER"
MARKER_CREATED=1
if [ ! -e "$MARKER" ]; then
  fail "failed to create marker $MARKER"
fi
out="$(armada_update_target "$OFFICIAL_REF")"
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "official ref returned 0 while personal marker present (auto-followed): '$out'"
fi
pass "official ref rejected while personal marker present (rc=$rc)"

echo "PASS: all personal update-target checks"
exit 0
