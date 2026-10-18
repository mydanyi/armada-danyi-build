#!/usr/bin/env bash
# Behavioural integration test for the personal-build upstream-sync helper
# (tests/../sync-upstream.sh <repo>). Real local git fixtures only: no network,
# no push, no HOME/CODEX_HOME redefinition. A missing helper is a hard FAIL.
set -euo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$TESTS_DIR/../sync-upstream.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
sum()  { sha256sum -- "$1" | cut -d' ' -f1; }

[[ -f "$HELPER" ]] || fail "helper missing: $HELPER (expected tests/../sync-upstream.sh <repo>)"
: "${TEST_TMP_ROOT:?TEST_TMP_ROOT must be set to the task writable directory}"
[[ "$TEST_TMP_ROOT" == /* && "$TEST_TMP_ROOT" != "/" && -w "$TEST_TMP_ROOT" ]] \
    || fail "TEST_TMP_ROOT must be an absolute writable task dir: $TEST_TMP_ROOT"
WORK="$(mktemp -d "$TEST_TMP_ROOT/sync-upstream.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

# Hermetic git: ignore host/system config, signing and hooks; leave HOME alone.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE GITHUB_OUTPUT GITHUB_STEP_SUMMARY 2>/dev/null || true
git_() { git -c commit.gpgsign=false -c core.hooksPath=/dev/null \
             -c user.name='Sync Fixture' -c user.email='sync@example.invalid' "$@"; }

U="$WORK/upstream.git" US="$WORK/upstream-src" P="$WORK/personal"
PB="$P/.github/workflows/personal-build.yml" SY="$P/.github/workflows/sync-upstream.yml"
PRIV="$P/plugins/private.txt"

# Upstream fixture: one official workflow of >=8 stable lines so the personal
# rename stays detectable after an upstream append, plus a README.
git_ init -q --bare "$U"; git_ -C "$U" symbolic-ref HEAD refs/heads/main
git_ init -q "$US"; git_ -C "$US" symbolic-ref HEAD refs/heads/main
mkdir -p "$US/.github/workflows"
cat > "$US/.github/workflows/build.yml" <<'YAML'
name: Build
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - run: echo build
YAML
printf 'upstream readme\n' > "$US/README.md"
git_ -C "$US" add -A; git_ -C "$US" commit -qm 'upstream: init'
git_ -C "$US" push -q "$U" main
U0="$(git_ -C "$US" rev-parse HEAD)"

# Personal repo: relocate the official workflow, add 2 personal workflows and a
# personal plugin file. No origin remote, so the helper can never push anywhere.
git_ clone -q "$U" "$P"; git_ -C "$P" remote remove origin
mkdir -p "$P/.github/upstream-workflows" "$P/plugins"
git_ -C "$P" mv .github/workflows/build.yml .github/upstream-workflows/build.yml
printf 'name: Personal build\non: [workflow_dispatch]\n' > "$PB"
printf 'name: Sync upstream\non: [workflow_dispatch]\n' > "$SY"
printf 'do not sync\n' > "$PRIV"
git_ -C "$P" add -A; git_ -C "$P" commit -qm 'personal: relocate official workflows, add personal layer'
P0="$(git_ -C "$P" rev-parse HEAD)"
H_PB="$(sum "$PB")" H_SY="$(sum "$SY")" H_PRIV="$(sum "$PRIV")"

keep_personal() {  # keep_personal <label>
    [[ "$(sum "$PB")" == "$H_PB" && "$(sum "$SY")" == "$H_SY" && "$(sum "$PRIV")" == "$H_PRIV" ]] \
        || fail "$1: personal workflows or plugins/private.txt changed"
}
run() {  # run <label>: invoke the helper offline against the personal fixture
    OUT="$WORK/$1.out"; set +e
    UPSTREAM_URL="$U" bash "$HELPER" "$P" >"$OUT" 2>&1; RC=$?
    set -e
}
ok()  { [[ "$RC" -eq 0 ]] || fail "$1: helper exited $RC: $(cat "$OUT")"; }
chg() { grep -Eq "changed=$2" "$OUT" || fail "$1: expected changed=$2: $(cat "$OUT")"; }

# Case 1 -- a new upstream commit merges cleanly and keeps the personal layer.
printf 'more upstream\n' > "$US/system.txt"
git_ -C "$US" add -A; git_ -C "$US" commit -qm 'upstream: add system file'
git_ -C "$US" push -q "$U" main; U1="$(git_ -C "$US" rev-parse HEAD)"
run case1; ok case1; chg case1 true
git_ -C "$P" merge-base --is-ancestor "$U1" HEAD || fail 'case1: upstream HEAD not merged'
git_ -C "$P" merge-base --is-ancestor "$P0" HEAD || fail 'case1: personal history lost'
[[ "$(wc -w <<<"$(git_ -C "$P" show -s --format=%P HEAD)")" -eq 2 ]] \
    || fail 'case1: expected a two-parent merge commit'
keep_personal case1
pass 'case1: upstream commit merged, personal layer intact'

# Case 2 -- upstream edits build.yml and adds a new official workflow: both must
# end up only under .github/upstream-workflows, keeping .github/workflows personal.
cat >> "$US/.github/workflows/build.yml" <<'YAML'
  notify:
    runs-on: ubuntu-24.04
    steps:
      - run: echo notify
YAML
printf 'name: New official\non: [workflow_dispatch]\n' > "$US/.github/workflows/official-new.yml"
git_ -C "$US" add -A; git_ -C "$US" commit -qm 'upstream: extend + add workflow'
git_ -C "$US" push -q "$U" main; U2="$(git_ -C "$US" rev-parse HEAD)"
run case2; ok case2; chg case2 true
git_ -C "$P" merge-base --is-ancestor "$U2" HEAD || fail 'case2: upstream HEAD not merged'
cmp -s "$P/.github/upstream-workflows/build.yml" "$US/.github/workflows/build.yml" \
    || fail 'case2: relocated build.yml lacks the upstream edit'
[[ ! -e "$P/.github/workflows/build.yml" ]] || fail 'case2: build.yml reappeared in .github/workflows'
cmp -s "$P/.github/upstream-workflows/official-new.yml" "$US/.github/workflows/official-new.yml" \
    || fail 'case2: new official workflow not relocated'
[[ ! -e "$P/.github/workflows/official-new.yml" ]] || fail 'case2: new official workflow leaked into .github/workflows'
[[ "$(cd "$P/.github/workflows" && ls -1 | sort | tr '\n' ' ')" == 'personal-build.yml sync-upstream.yml ' ]] \
    || fail 'case2: .github/workflows holds unexpected entries'
keep_personal case2
pass 'case2: official workflows relocated to .github/upstream-workflows'

# Case 3 -- no upstream change: same HEAD, changed=false, clean tree.
B="$(git_ -C "$P" rev-parse HEAD)"
run case3; ok case3; chg case3 false
[[ "$(git_ -C "$P" rev-parse HEAD)" == "$B" ]] || fail 'case3: HEAD moved with no upstream change'
[[ -z "$(git_ -C "$P" status --porcelain)" ]] || fail 'case3: working tree not clean'
pass 'case3: no upstream change -> changed=false, HEAD unchanged'

# Case 3b -- plugin-only change: upstream has nothing new, but the repo's own
# personal-build/sync-plugins.py bumps a lock entry. The first run must commit
# the plugin change as a clean commit and report changed=true; the second run
# is a no-op with changed=false and an unchanged HEAD.
mkdir -p "$P/personal-build"
cat > "$P/personal-build/plugins.lock.json" <<'JSON'
[
  {
    "name": "armada-installer",
    "version": "0.1.0",
    "url": "https://github.com/mydanyi/armada-installer/releases/download/v0.1.0/armada-installer-0.1.0.zip",
    "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
    "directory": "armada-installer"
  }
]
JSON
cat > "$P/personal-build/sync-plugins.py" <<'PY'
#!/usr/bin/env python3
"""Process-boundary stub: bump armada-installer 0.1.0 -> 0.2.0 once."""
import json
import os
import sys

repo = sys.argv[1]
lock = os.path.join(repo, "personal-build", "plugins.lock.json")
with open(lock, encoding="utf-8") as handle:
    entries = json.load(handle)
updated = []
for entry in entries:
    if entry.get("version") == "0.1.0":
        entry["version"] = "0.2.0"
        updated.append(entry["name"])
if updated:
    with open(lock, "w", encoding="utf-8") as handle:
        json.dump(entries, handle, indent=2)
        handle.write("\n")
print(json.dumps({"updated": updated, "skipped": []}))
PY
git_ -C "$P" add -A; git_ -C "$P" commit -qm 'personal: add plugin lock and sync helper'
G0="$(git_ -C "$P" rev-parse HEAD)"
run case3b; ok case3b; chg case3b true
[[ "$(git_ -C "$P" rev-parse HEAD)" != "$G0" ]] \
    || fail 'case3b: plugin update was not committed'
[[ -z "$(git_ -C "$P" status --porcelain)" ]] \
    || fail 'case3b: working tree not clean after plugin commit'
grep -qF '"version": "0.2.0"' "$P/personal-build/plugins.lock.json" \
    || fail 'case3b: lock was not updated to 0.2.0'
G1="$(git_ -C "$P" rev-parse HEAD)"
run case3b_again; ok case3b_again; chg case3b_again false
[[ "$(git_ -C "$P" rev-parse HEAD)" == "$G1" ]] \
    || fail 'case3b: second plugin run moved HEAD without a change'
grep -qF '"version": "0.2.0"' "$P/personal-build/plugins.lock.json" \
    || fail 'case3b: lock version changed on the no-op run'
pass 'case3b: plugin-only change committed once, second run no-op'

# Case 4 -- both sides edit README: helper must fail, restore HEAD, abort the merge.
printf 'personal edit\n' > "$P/README.md"
git_ -C "$P" add -A; git_ -C "$P" commit -qm 'personal: edit README'
P1="$(git_ -C "$P" rev-parse HEAD)"
printf 'upstream edit\n' > "$US/README.md"
git_ -C "$US" add -A; git_ -C "$US" commit -qm 'upstream: edit README'
git_ -C "$US" push -q "$U" main; U4="$(git_ -C "$US" rev-parse HEAD)"
run case4
[[ "$RC" -ne 0 ]] || fail "case4: helper succeeded on a conflicting merge: $(cat "$OUT")"
[[ "$(git_ -C "$P" rev-parse HEAD)" == "$P1" ]] || fail 'case4: HEAD not restored'
[[ "$(cat "$P/README.md")" == 'personal edit' ]] || fail 'case4: personal content lost'
[[ ! -e "$P/.git/MERGE_HEAD" ]] || fail 'case4: merge not aborted (MERGE_HEAD present)'
[[ -z "$(git_ -C "$P" ls-files -u)" ]] || fail 'case4: unmerged index entries remain'
[[ -z "$(git_ -C "$P" status --porcelain)" ]] || fail 'case4: working tree not clean'
keep_personal case4
[[ "$(git_ -C "$U" rev-parse main)" == "$U4" ]] || fail 'case4: helper modified the upstream repository'
pass 'case4: conflict aborted, HEAD/index preserved'

printf '\nsync-upstream tests passed\n'
