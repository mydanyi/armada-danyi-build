#!/usr/bin/env bash
# Armada personal build -- NAS transfer helper.
#
# Runs inside the self-hosted Docker runner and talks to the NAS over
# SSH/rsync. Everything it writes on the NAS lives under
#     <ARMADA_NAS_TARGET>/runs/<BUILD_ID>/{source,output,logs,evidence}
# so a run only ever creates files inside its own directory tree. It never
# deletes anything on the NAS and never prunes anything anywhere.
#
# Modes:
#   source    Run before the build. Probe that the run directory on the NAS is
#             writable, then archive the checkout (minus .git/, node_modules/,
#             build outputs/caches and any ssh material) so the exact inputs are
#             preserved before any heavy work starts. A failure here stops the
#             workflow before the build begins.
#   results   Run after the build (workflow `always()`). Publish whatever
#             TASK_ROOT/output/ holds (minus the raw disk images: disk.raw and
#             any *.raw, whose logs already describe them), TASK_ROOT/logs/ and
#             small metadata to the NAS, so a failed run still keeps its kernel
#             artifacts and evidence. Transfer-only: success is judged solely by
#             the rsync exit status; the uploaded image is never re-read or
#             re-hashed here (the NAS holds no hashing step).
#
# Required environment (the runner provides ARMADA_NAS_*; the workflow exports
# TASK_ROOT/SRC_ROOT/BUILD_ID via $GITHUB_ENV):
#   ARMADA_NAS_KEY          SSH private key: either a path to a readable key
#                           file, or the key material itself (written to a 0600
#                           temp file that is removed on exit).
#   ARMADA_NAS_KNOWN_HOSTS  known_hosts: a path to a readable file, or content.
#   ARMADA_NAS_TARGET       <user>@<host>:<root>, e.g.
#                           user@nas:/absolute/task-root
#                           <root> is the per-task NAS root directory.
#   TASK_ROOT               Absolute path of this task's server runtime space.
#   SRC_ROOT                Absolute path of the checkout on this runner.
#   BUILD_ID                "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}".
#
# Positional overrides: "$0 <source|results> [TASK_ROOT] [SRC_ROOT] [BUILD_ID]".
#
# rsync notes:
#   * -a with --no-owner --no-group, because build outputs are owned by server
#     root and the NAS user (danyi) cannot chown them.
#   * --secluded-args (-s) keeps remote paths containing spaces and Chinese
#     characters intact.
#   * never --delete, so pre-existing NAS files are never removed.
set -euo pipefail

MODE="${1:-}"
case "${MODE}" in
    source | results) ;;
    *) echo "usage: $0 <source|results> [TASK_ROOT] [SRC_ROOT] [BUILD_ID]" >&2; exit 2 ;;
esac

TASK_ROOT="${2:-${TASK_ROOT:-}}"
SRC_ROOT="${3:-${SRC_ROOT:-}}"
BUILD_ID="${4:-${BUILD_ID:-}}"

: "${TASK_ROOT:?TASK_ROOT is required (absolute path)}"
: "${SRC_ROOT:?SRC_ROOT is required (absolute path)}"
: "${BUILD_ID:?BUILD_ID is required}"
: "${ARMADA_NAS_KEY:?ARMADA_NAS_KEY is required (key file path or key material)}"
: "${ARMADA_NAS_KNOWN_HOSTS:?ARMADA_NAS_KNOWN_HOSTS is required (known_hosts path or content)}"
: "${ARMADA_NAS_TARGET:?ARMADA_NAS_TARGET is required (<user>@<host>:<root>)}"

[[ "${TASK_ROOT}" == /* ]] || { echo "ERROR: TASK_ROOT must be absolute: ${TASK_ROOT}" >&2; exit 2; }
[[ "${SRC_ROOT}" == /* ]] || { echo "ERROR: SRC_ROOT must be absolute: ${SRC_ROOT}" >&2; exit 2; }

# --- Split the NAS target into "<user>@<host>" and the absolute remote root. --
NAS_USERHOST="${ARMADA_NAS_TARGET%%:*}"
NAS_ROOT="${ARMADA_NAS_TARGET#*:}"
[[ "${NAS_USERHOST}" == *@* ]] \
    || { echo "ERROR: ARMADA_NAS_TARGET must look like <user>@<host>:<path>: ${ARMADA_NAS_TARGET}" >&2; exit 2; }
[[ "${NAS_ROOT}" == /* ]] \
    || { echo "ERROR: ARMADA_NAS_TARGET path must be absolute: ${NAS_ROOT}" >&2; exit 2; }

REMOTE_RUN="${NAS_ROOT}/runs/${BUILD_ID}"

# --- Materialise SSH credentials outside the checkout we archive. ------------
# Credentials always live inside this task's own work/ directory -- never in the
# system temp -- so nothing sensitive can land outside TASK_ROOT.
mkdir -p "${TASK_ROOT}/work"
SECRET_DIR="$(mktemp -d "${TASK_ROOT}/work/.nas-secrets.XXXXXX")"
KEY_FILE="${SECRET_DIR}/id_nas"
KNOWN_HOSTS_FILE="${SECRET_DIR}/known_hosts"

# Close only this task's own credential files. The long-lived runner, its
# caches and images are deliberately left untouched.
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    rm -rf "${SECRET_DIR}"
    exit "${rc}"
}
trap cleanup EXIT INT TERM

materialize() {
    local value="$1" dest="$2"
    if [[ -f "${value}" ]]; then
        cp -f -- "${value}" "${dest}"
    else
        printf '%s\n' "${value}" > "${dest}"
    fi
    chmod 600 "${dest}"
}
materialize "${ARMADA_NAS_KEY}" "${KEY_FILE}"
materialize "${ARMADA_NAS_KNOWN_HOSTS}" "${KNOWN_HOSTS_FILE}"

# rsync's -e string is split on whitespace, so keep the temp paths space-free.
[[ "${KEY_FILE}" != *[[:space:]]* && "${KNOWN_HOSTS_FILE}" != *[[:space:]]* ]] \
    || { echo "ERROR: credential temp paths must not contain whitespace" >&2; exit 2; }

SSH_OPTS=(
    -i "${KEY_FILE}"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}"
)
RSYNC_SSH="ssh -i ${KEY_FILE} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${KNOWN_HOSTS_FILE}"

# Quote a value for safe use inside a remote `sh -c` command string.
shq() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

remote() {
    ssh "${SSH_OPTS[@]}" "${NAS_USERHOST}" "$*"
}

# The checkout minus VCS, dependencies, build outputs/caches and ssh material.
SOURCE_EXCLUDES=(
    --exclude=.git
    --exclude=node_modules
    --exclude=/output
    --exclude=/cache
    --exclude=.ssh
)

sync_up() {  # sync_up <src (dir/ or file)> <remote subdir under the run dir>
    local src="$1" dest="$2"
    rsync -a --no-owner --no-group -s -e "${RSYNC_SSH}" \
        "${src}" "${NAS_USERHOST}:${REMOTE_RUN}/${dest}"
}

ensure_remote_dirs() {
    remote "mkdir -p $(shq "${REMOTE_RUN}/source") $(shq "${REMOTE_RUN}/output") $(shq "${REMOTE_RUN}/logs") $(shq "${REMOTE_RUN}/evidence")"
}

# Confirm the run directory really accepts writes before relying on it.
probe_writable() {
    remote "p=$(shq "${REMOTE_RUN}/.write-probe"); : > \"\$p\" && rm -f \"\$p\""
}

archive_source() {
    rsync -a --no-owner --no-group -s -e "${RSYNC_SSH}" \
        "${SOURCE_EXCLUDES[@]}" \
        "${SRC_ROOT}/" "${NAS_USERHOST}:${REMOTE_RUN}/source/"
}

do_source() {
    ensure_remote_dirs
    probe_writable
    echo "==> NAS task directory is writable; archiving source to the configured NAS task directory"
    archive_source
    echo "==> Source archive complete"
}

# Small, non-heavy metadata only (never the rootfs.tar cache).
publish_metadata() {
    local f
    for f in \
        "${TASK_ROOT}/work/build-source.txt" \
        "${TASK_ROOT}/work/rootfs-ref.txt" \
        "${TASK_ROOT}/output/SHA256SUMS.txt"; do
        [[ -f "${f}" ]] || continue
        echo "==> evidence: $(basename "${f}")"
        sync_up "${f}" evidence/
    done
}

do_results() {
    ensure_remote_dirs
    probe_writable

    # Re-archive the source idempotently so a failed run still leaves both the
    # logs and the exact inputs on the NAS (rsync skips unchanged files).
    echo "==> Ensuring source archive is present"
    archive_source

    if [[ -d "${TASK_ROOT}/logs" ]]; then
        echo "==> Publishing logs"
        sync_up "${TASK_ROOT}/logs/" logs/
    fi

    # Always publish whatever the task's output/ holds -- on failure this keeps
    # the kernel artifacts and evidence metadata the run did produce -- but never
    # the raw disk image: disk.raw and any *.raw are useless when the run failed
    # and the logs already describe them. Release split volumes are also skipped
    # -- both the OCI byte parts (*.part*) and the install 7z volumes
    # (*.7z.NNN): the NAS keeps the complete .img.gz and .oci.tar plus the small
    # metadata, while the volumes exist only for the GitHub Release, so the same
    # package is not uploaded to the NAS a second time.
    if [[ -d "${TASK_ROOT}/output" ]]; then
        echo "==> Publishing output (excluding raw disk images and release volumes)"
        rsync -a --no-owner --no-group -s -e "${RSYNC_SSH}" \
            --exclude='/image/disk.raw' \
            --exclude='*.raw' \
            --exclude='/release/*.part*' \
            --exclude='/release/*.7z.[0-9][0-9][0-9]' \
            "${TASK_ROOT}/output/" "${NAS_USERHOST}:${REMOTE_RUN}/output/"
    else
        echo "==> No ${TASK_ROOT}/output directory to publish"
    fi

    echo "==> Publishing small metadata to evidence/"
    publish_metadata
}

case "${MODE}" in
    source) do_source ;;
    results) do_results ;;
esac
