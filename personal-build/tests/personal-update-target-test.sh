#!/usr/bin/env bash
# Behavioural test for armada_update_target (personal-build update target).
#
# Contract under test:
#   * no personal marker: an official ref resolves to its canonical ghcr target;
#     a local (non-registry) OCI ref is rejected and never falls back official.
#     An explicit danyi official state must route to the personal target, never
#     to a bogus ghcr ":danyi" tag.
#   * personal marker + no explicit channel selection: the personal target
#     "github.com/mydanyi/armada-danyi-build danyi" is returned -- even when the
#     booted ref names an official channel, and even when a legacy official
#     state still says beta (the personal image default-selects 单翼版).
#   * personal marker + explicit official selection (stable/beta/testing) in the
#     personal state: the matching official ghcr target is returned.
#   * personal marker + explicit danyi selection: the personal target again.
#
# Only the channel-state *paths* are redirected into fixtures; the decision
# logic in update-lib is exercised exactly as shipped, with the official and
# personal states kept as two independent files.
#
# Expected RED until update-lib implements the danyi/personal routing.
set -u
export LC_ALL=C

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

MARKER="/usr/share/armada/personal-build/plugins.lock.json"
CANONICAL="ghcr.io/armada-os/armada"
PERSONAL_TARGET="github.com/mydanyi/armada-danyi-build danyi"
OFFICIAL_REF="ostree-unverified-registry:ghcr.io/armada-os/armada:beta"
LOCAL_REF="ostree-unverified-image:oci-archive:/var/lib/armada-danyi-updates/test/test.oci.tar"

WORK="${TMPDIR:-/tmp}/personal-update-target.$$"
mkdir -p "$WORK" || { echo "FAIL: cannot create $WORK" >&2; exit 1; }

MARKER_CREATED=0
# Only remove the marker if THIS test created it.
cleanup() {
  if [ "$MARKER_CREATED" -eq 1 ]; then
    rm -f "$MARKER"
  fi
  rm -rf -- "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

# shellcheck source=/dev/null
. "$SRC_ROOT/system_files/usr/lib/armada/update-lib" || fail "cannot source update-lib from $SRC_ROOT"

# Redirect only the writable state paths into the fixture tree (path, not
# logic): the official channel state and the personal (single-wing) channel
# state are two independent files, both under WORK.
OFFICIAL_CHANNEL_STATE="$WORK/official-update-channel"
PERSONAL_CHANNEL_STATE="$WORK/personal-update-channel"
ARMADA_CHANNEL_STATE="$OFFICIAL_CHANNEL_STATE"
ARMADA_PERSONAL_CHANNEL_STATE="$PERSONAL_CHANNEL_STATE"

[ -e "$MARKER" ] && fail "marker unexpectedly present before test: $MARKER"

# 1) No marker: the official beta ref resolves to the canonical official target.
out="$(armada_update_target "$OFFICIAL_REF")" || fail "official ref failed with no marker"
[ "$out" = "$CANONICAL beta" ] || fail "official ref -> '$out', expected '$CANONICAL beta'"
pass "official beta resolves to '$CANONICAL beta'"

# 2) No marker: a local OCI ref is rejected and never falls back to official.
if out="$(armada_update_target "$LOCAL_REF")"; then
  fail "local OCI ref fell back to official: '$out'"
fi
pass "local OCI ref rejected without fallback"

# 2b) No marker + an explicit danyi official state: the personal target, never a
#     bogus ghcr ":danyi" tag.
printf 'danyi\n' > "$OFFICIAL_CHANNEL_STATE"
out="$(armada_update_target "$OFFICIAL_REF")" \
  || fail "explicit danyi (official state) failed without a marker"
[ "$out" = "$PERSONAL_TARGET" ] \
  || fail "official state danyi -> '$out', expected '$PERSONAL_TARGET'"
rm -f "$OFFICIAL_CHANNEL_STATE"
pass "official state danyi resolves to '$PERSONAL_TARGET' without a marker"

# --- personal image: create the marker (only remove what we create) ----------
mkdir -p "$(dirname "$MARKER")"
: > "$MARKER"
MARKER_CREATED=1
[ -e "$MARKER" ] || fail "failed to create marker $MARKER"

# Re-source the library as a brand-new process (as if the machine booted a
# different system image), then re-point the writable state paths at the
# fixtures so the fresh definitions cannot override them.
# shellcheck source=/dev/null
. "$SRC_ROOT/system_files/usr/lib/armada/update-lib" \
  || fail "cannot re-source update-lib from $SRC_ROOT"
ARMADA_CHANNEL_STATE="$OFFICIAL_CHANNEL_STATE"
ARMADA_PERSONAL_CHANNEL_STATE="$PERSONAL_CHANNEL_STATE"

# 3) Marker + a legacy official state (beta) but no personal state: the personal
#    default wins -- the stale official state must not leak through.
printf 'beta\n' > "$OFFICIAL_CHANNEL_STATE"
rm -f "$PERSONAL_CHANNEL_STATE"
out="$(armada_update_target "$OFFICIAL_REF")" \
  || fail "personal target unavailable with marker present"
[ "$out" = "$PERSONAL_TARGET" ] \
  || fail "marker default (legacy official beta) -> '$out', expected '$PERSONAL_TARGET'"
pass "legacy official beta does not override the personal default"

out="$(armada_update_target "$LOCAL_REF")" \
  || fail "personal target unavailable for a local booted ref"
[ "$out" = "$PERSONAL_TARGET" ] || fail "marker + local ref -> '$out', expected '$PERSONAL_TARGET'"
pass "personal marker + local booted ref -> '$PERSONAL_TARGET'"

# 4) Marker + explicit official selection (recorded in the personal state): the
#    official ghcr target wins even while the legacy official state says beta.
for channel in stable beta testing; do
  printf '%s\n' "$channel" > "$PERSONAL_CHANNEL_STATE"
  out="$(armada_update_target "$OFFICIAL_REF")" \
    || fail "explicit official '$channel' failed with marker present"
  [ "$out" = "$CANONICAL $channel" ] \
    || fail "explicit '$channel' -> '$out', expected '$CANONICAL $channel'"
done
pass "explicit official selection returns the official ghcr target"

# 5) Marker + explicit danyi selection (personal state): back to the personal target.
printf 'danyi\n' > "$PERSONAL_CHANNEL_STATE"
out="$(armada_update_target "$OFFICIAL_REF")" || fail "explicit danyi selection failed"
[ "$out" = "$PERSONAL_TARGET" ] || fail "explicit danyi -> '$out', expected '$PERSONAL_TARGET'"
pass "explicit danyi selection returns '$PERSONAL_TARGET'"

echo "PASS: all personal update-target checks"
exit 0
