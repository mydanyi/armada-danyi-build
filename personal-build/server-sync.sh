#!/usr/bin/env bash
# Armada personal build -- daily upstream sync driver (server timer entrypoint).
#
# Starts inside the existing long-lived Docker runner on 192.168.88.9, launched
# once a day by armada-personal-upstream-sync.timer:
#     docker exec armada-personal-build-runner bash <ARMADA_EXECUTION_BASE>/automation/server-sync.sh
# It takes over the daily merge the GitHub Actions schedule used to run and
# reuses personal-build/sync-upstream.sh unchanged -- this script only provides
# the checkout and drives the push (the helper never pushes itself).
#
# Scope: it touches exactly one cache, ${ARMADA_EXECUTION_BASE}/automation/
# checkout, which this task owns; no other repository is cloned, reset or
# forced. It never builds an image, dispatches a workflow, reads the NAS or
# restarts anything, and never prints deploy-key contents.
#
# Env:
#   ARMADA_EXECUTION_BASE  (required, absolute)  Runner task root; must exist.
#     e.g. /home/danyi/codex-exec/armada-personal-build-20261011-617f1c87
set -euo pipefail

: "${ARMADA_EXECUTION_BASE:?ARMADA_EXECUTION_BASE must be set by the runner}"
[[ "${ARMADA_EXECUTION_BASE}" == /* ]] \
    || { echo "ERROR: ARMADA_EXECUTION_BASE must be absolute: ${ARMADA_EXECUTION_BASE}" >&2; exit 2; }
[[ -d "${ARMADA_EXECUTION_BASE}" ]] \
    || { echo "ERROR: ARMADA_EXECUTION_BASE does not exist: ${ARMADA_EXECUTION_BASE}" >&2; exit 2; }

# This task's own execution cache and the repo it syncs (the same private
# repository the manual workflow pushes to). Nothing else is ever addressed.
CHECKOUT="${ARMADA_EXECUTION_BASE}/automation/checkout"
REPO_URL="git@ssh.github.com:mydanyi/armada-danyi-build.git"

# The dedicated, repo-scoped write deploy key provisioned on the runner.
KEY="${ARMADA_EXECUTION_BASE}/credentials/upstream-sync-ed25519"
KNOWN="${ARMADA_EXECUTION_BASE}/credentials/github-sync-known-hosts"
[[ -f "${KEY}" ]] || { echo "ERROR: deploy key not found: ${KEY}" >&2; exit 1; }
[[ -f "${KNOWN}" ]] || { echo "ERROR: known_hosts not found: ${KNOWN}" >&2; exit 1; }

# Same SSH transport as the manual workflow: the write key over github.com on
# port 443 (host-key alias). The key is passed to ssh via -i; its contents are
# never printed here.
export GIT_SSH_COMMAND="ssh -i ${KEY} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${KNOWN} -o HostKeyAlias=github.com -o ConnectTimeout=20 -p 443"

# The helper appends to GITHUB_OUTPUT when it is set; drop any inherited value
# so this run cannot disturb another Actions context. Its stdout is our only
# result channel. HOME/CODEX_HOME are deliberately left untouched.
unset GITHUB_OUTPUT

# ---- the one cache this task owns -------------------------------------------
if [[ -d "${CHECKOUT}/.git" ]]; then
    origin_url="$(git -C "${CHECKOUT}" remote get-url origin)"
    [[ "${origin_url}" == "${REPO_URL}" ]] \
        || { echo "ERROR: origin of ${CHECKOUT} is '${origin_url}', expected '${REPO_URL}'; refusing to touch it" >&2; exit 1; }
    [[ -z "$(git -C "${CHECKOUT}" status --porcelain)" ]] \
        || { echo "ERROR: working tree of ${CHECKOUT} is not clean; refusing to sync" >&2; exit 1; }
    echo "==> Fetching origin main into ${CHECKOUT}"
    git -C "${CHECKOUT}" fetch origin main
    git -C "${CHECKOUT}" checkout -B server-upstream-sync origin/main
else
    echo "==> First run: cloning ${REPO_URL} -> ${CHECKOUT}"
    git clone --branch main "${REPO_URL}" "${CHECKOUT}"
fi

# ---- merge upstream with the shared helper, then push -----------------------
# The helper only prepares a local merge commit; the push below is ours. Capture
# its stdout in a plain variable (no temp file or manifest) and echo it, so
# journald keeps the full record.
set +e
out="$(bash "${CHECKOUT}/personal-build/sync-upstream.sh" "${CHECKOUT}")"
rc=$?
set -e
printf '%s\n' "${out}"
(( rc == 0 )) || { echo "ERROR: sync-upstream.sh failed (exit ${rc}); not pushing" >&2; exit "${rc}"; }

# Push only on a complete 'changed=true' line, and never with --force.
if grep -qx 'changed=true' <<< "${out}"; then
    echo "==> New upstream commit merged; pushing HEAD:main"
    git -C "${CHECKOUT}" push origin HEAD:main
elif grep -qx 'changed=false' <<< "${out}"; then
    echo "no changes"
else
    echo "ERROR: sync-upstream.sh emitted no complete changed= line; not pushing" >&2
    exit 1
fi
