#!/usr/bin/env bash
# Armada personal build -- upstream sync helper.
#
# Merges new commits from armada-os/armada main into the personal build repo and
# keeps the personal layer (the two custom workflows, Chinese/plugin/unmerged
# patches, build config) intact; official workflows upstream adds are relocated
# out of .github/workflows. When the repo carries a plugin lock and helper, the
# bundled Decky plugin releases are refreshed as well. It only prepares local
# commits -- never a push, PR or build dispatch (the workflow decides whether to
# push).
#
# Usage: bash personal-build/sync-upstream.sh <repo-path>
#   UPSTREAM_URL   upstream git URL (default https://github.com/armada-os/armada.git;
#                  tests use a local fixture). origin is never changed.
#   GITHUB_OUTPUT  when set, changed/new_sha/plugins_updated/plugins_skipped are
#                  appended for the workflow.
#
# Requires a clean tree (uncommitted work is never reset or overwritten); on a
# conflict it aborts the merge and restores the original HEAD/index.
set -euo pipefail

REPO="${1:-}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/armada-os/armada.git}"

[[ -n "${REPO}" ]] || { echo "usage: $0 <repo-path>" >&2; exit 2; }
git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "ERROR: not a git working tree: ${REPO}" >&2; exit 2; }

# The two personal workflows that must never move and never be overwritten.
PROTECTED=(personal-build.yml sync-upstream.yml)
BOT_NAME="armada-upstream-sync"
BOT_EMAIL="armada-upstream-sync@users.noreply.github.com"

# Only a merge this helper started may be aborted on exit; a MERGE_HEAD that
# already existed before we ran is somebody else's state and is left untouched.
MERGE_STARTED=0

# Every git command runs as this bot with signing disabled, via -c (no config written).
git_() {
    git -C "${REPO}" \
        -c commit.gpgsign=false \
        -c user.name="${BOT_NAME}" \
        -c user.email="${BOT_EMAIL}" "$@"
}

emit() {  # emit <key> <value>   -- stdout always; GITHUB_OUTPUT when present
    printf '%s=%s\n' "$1" "$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
    fi
}

# Whatever the exit path, never leave a half-finished merge behind.
on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    if (( MERGE_STARTED )) && git -C "${REPO}" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        echo "==> Aborting in-progress merge" >&2
        git -C "${REPO}" merge --abort || true
    fi
    exit "${rc}"
}
trap on_exit EXIT INT TERM

# 1. A clean tree is a hard precondition; we never clobber uncommitted work.
if [[ -n "$(git_ status --porcelain)" ]]; then
    echo "ERROR: working tree is not clean; refusing to sync" >&2
    git_ status --short >&2 || true
    exit 1
fi

# The HEAD this run started from: plugins alone may move it forward.
START_SHA="$(git_ rev-parse HEAD)"

# Refresh the bundled plugin releases through the repository's own helper and
# commit only the lock plus the private package directory. Repos without the
# lock/helper (older fixtures, upstream checkouts) simply skip this step.
sync_plugins() {
    local pb="${REPO}/personal-build"
    if [[ ! -f "${pb}/plugins.lock.json" || ! -f "${pb}/sync-plugins.py" ]]; then
        echo "==> Plugin releases: no lock/helper in this repo; skipping"
        return 0
    fi

    local out rc
    set +e
    out="$(python3 "${pb}/sync-plugins.py" "${REPO}")"
    rc=$?
    set -e
    if (( rc != 0 )); then
        echo "ERROR: plugin release sync failed (exit ${rc}); refusing to continue" >&2
        exit 1
    fi

    local stats
    if ! stats="$(printf '%s' "${out}" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(len(data["updated"]))
print(len(data["skipped"]))
print(", ".join(data["updated"]) or "-")
print(", ".join(data["skipped"]) or "-")
')"; then
        echo "ERROR: plugin release sync did not print the expected JSON" >&2
        exit 1
    fi

    local fields
    mapfile -t fields <<< "${stats}"
    echo "==> Plugin releases: updated ${fields[0]} (${fields[2]}); skipped ${fields[1]} (${fields[3]})"
    emit plugins_updated "${fields[0]}"
    emit plugins_skipped "${fields[1]}"

    git_ add -A -- personal-build/plugins.lock.json
    if [[ -d "${pb}/plugin-assets" ]]; then
        git_ add -A -- personal-build/plugin-assets
    fi
    if ! git_ diff --cached --quiet; then
        echo "==> Committing bundled plugin release update"
        git_ commit -q -m "chore: sync bundled Decky plugin releases"
    else
        echo "==> Plugin releases: nothing to commit"
    fi
}

# 2. Fetch upstream main into a remote-tracking ref; origin is left untouched.
echo "==> Fetching ${UPSTREAM_URL} main"
git_ fetch --no-tags "${UPSTREAM_URL}" "+main:refs/remotes/upstream/main"
UP_SHA="$(git_ rev-parse refs/remotes/upstream/main)"

# 3. Upstream main is already an ancestor of our HEAD: nothing to merge, but a
#    newer bundled plugin release may still need committing.
if git_ merge-base --is-ancestor "${UP_SHA}" HEAD; then
    echo "==> Upstream main (${UP_SHA}) is already in history; nothing to merge"
    sync_plugins
    FINAL_SHA="$(git_ rev-parse HEAD)"
    emit new_sha "${FINAL_SHA}"
    if [[ "${FINAL_SHA}" == "${START_SHA}" ]]; then
        emit changed false
    else
        emit changed true
    fi
    exit 0
fi

# 4. Stage a --no-ff merge without committing, so the relocation below is included.
echo "==> Merging upstream ${UP_SHA}"
MERGE_STARTED=1
if ! git_ merge --no-ff --no-commit "${UP_SHA}"; then
    echo "ERROR: merge conflict; aborting and keeping the current HEAD" >&2
    while IFS= read -r f; do
        [[ -n "${f}" ]] && echo "  conflict: ${f}" >&2
    done < <(git_ diff --name-only --diff-filter=U)
    git_ merge --abort
    exit 1
fi

# 5. Keep .github/workflows personal-only: git mv every official workflow the merge
#    brought in. A workflow git tracked through a personal rename (an upstream edit
#    to an already-relocated file) never shows up here, so it is kept as-is.
WF_DIR="${REPO}/.github/workflows"
DST_DIR="${REPO}/.github/upstream-workflows"
mkdir -p "${DST_DIR}"
shopt -s nullglob
for path in "${WF_DIR}"/*; do
    name="$(basename "${path}")"
    keep=0
    for prot in "${PROTECTED[@]}"; do
        if [[ "${name}" == "${prot}" ]]; then keep=1; break; fi
    done
    if (( keep )); then continue; fi

    case "${name}" in
        *.yml | *.yaml) ;;
        *) continue ;;
    esac

    target="${DST_DIR}/${name}"
    if [[ -e "${target}" ]]; then
        if ! cmp -s -- "${path}" "${target}"; then
            echo "ERROR: ${name} already exists in .github/upstream-workflows and differs; refusing to overwrite" >&2
            exit 1
        fi
        git_ rm -q -f -- ".github/workflows/${name}"
    else
        echo "==> Relocating ${name} -> .github/upstream-workflows/${name}"
        git_ mv ".github/workflows/${name}" ".github/upstream-workflows/${name}"
    fi
done
shopt -u nullglob

# 6. Commit the merge (two parents) as the bot, signing disabled.
git_ commit -q --no-edit
MERGE_STARTED=0
NEW_SHA="$(git_ rev-parse HEAD)"
if [[ "$(wc -w <<< "$(git_ show -s --format=%P "${NEW_SHA}")")" -ne 2 ]]; then
    echo "ERROR: expected a two-parent merge commit at ${NEW_SHA}" >&2
    exit 1
fi

echo "==> Merged upstream ${UP_SHA} into ${NEW_SHA}"

# 7. Same plugin finish as the no-merge path; it may add one commit on top.
sync_plugins
FINAL_SHA="$(git_ rev-parse HEAD)"
emit changed true
emit new_sha "${FINAL_SHA}"
