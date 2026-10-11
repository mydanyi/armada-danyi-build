#!/usr/bin/env bash
# Armada personal kernel build — Docker runner orchestration.
#
# Runs the repo's unmodified packages/kernel/scripts/build-kernel.sh inside the
# cross-compile container built from personal-build/kernel.Containerfile, on the
# remote Docker daemon. The checkout is bind-mounted read-only; only the work,
# out and ccache mounts are writable.
#
# Everything is produced on the server-side runner resources described below.
# There is no fallback to building locally.
#
# Resource budget: --cpuset-cpus 0-15 (16 cores), --memory 24g.
#
# Params:
#   TASK_ROOT  (required, absolute)  This build task's server runtime space.
#                                    The exact directory varies per build task.
#                                    Provides logs/, output/kernel/, cache/.
#   SRC_ROOT   (optional, absolute)  Checkout root. Defaults to this script's
#                                    parent directory. Identical path on host
#                                    and runner.
#   BUILD_ID   (required, via env)   Suffix of the container name.
#
# Env:
#   DOCKER_HOST  Build daemon. Defaults to the Docker socket on the build
#                server: unix:///var/run/docker.sock, which the runner
#                container has bind-mounted. The runner may override.
#
# FAST is intentionally NOT set: every run extracts a pristine tree and
# re-applies the full series (including PR594 + the official 1021 scan-timeout
# work). Already-patched sources are never reused.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SRC_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Positional args override, env vars fall back.
TASK_ROOT="${1:-${TASK_ROOT:-}}"
SRC_ROOT="${2:-${SRC_ROOT:-${DEFAULT_SRC_ROOT}}}"

: "${BUILD_ID:?BUILD_ID is required (container name suffix)}"
: "${TASK_ROOT:?TASK_ROOT is required (absolute path to this task execution space)}"
[[ "${TASK_ROOT}" == /* ]] || { echo "ERROR: TASK_ROOT must be an absolute path: ${TASK_ROOT}" >&2; exit 2; }
[[ "${SRC_ROOT}" == /* ]] || { echo "ERROR: SRC_ROOT must be an absolute path: ${SRC_ROOT}" >&2; exit 2; }

IMAGE="local/armada-personal-kernel-builder:ubuntu24"
CONTAINERFILE="${SCRIPT_DIR}/kernel.Containerfile"
BUILD_CONTEXT="${SCRIPT_DIR}"
KERNEL_BUILD_SCRIPT="/work/source/packages/kernel/scripts/build-kernel.sh"

[[ -f "${CONTAINERFILE}" ]] || { echo "ERROR: missing containerfile ${CONTAINERFILE}" >&2; exit 2; }
[[ -f "${SRC_ROOT}/packages/kernel/scripts/build-kernel.sh" ]] \
    || { echo "ERROR: kernel build script not found under SRC_ROOT=${SRC_ROOT}" >&2; exit 2; }

# Local Docker socket of the build server (mounted into the runner container);
# the runner may already export DOCKER_HOST.
DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
export DOCKER_HOST

OUT_DIR="${TASK_ROOT}/output/kernel"
LOG_DIR="${TASK_ROOT}/logs"
LOG_FILE="${LOG_DIR}/kernel.log"
HOST_CCACHE_DIR="${TASK_ROOT}/cache/ccache"

# Work cache is keyed by the kernel package content hash so a changed source
# tree (e.g. a different patch set) always builds into a fresh directory.
PACKAGE_HASH="$(bash "${SRC_ROOT}/packages/package-hash.sh" kernel)"
WORK_CACHE="${TASK_ROOT}/cache/kernel/${PACKAGE_HASH}"

mkdir -p "${OUT_DIR}" "${LOG_DIR}" "${HOST_CCACHE_DIR}" "${WORK_CACHE}"

CONTAINER_NAME="armada-personal-kernel-${BUILD_ID}"
CONTAINER_CREATED=0

# Only ever stop/remove the exact container this run created. No prune, no
# touching anything else.
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ "${CONTAINER_CREATED}" == "1" ]]; then
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    exit "${rc}"
}
trap cleanup EXIT INT TERM

echo "==> Building builder image ${IMAGE}"
docker build -t "${IMAGE}" -f "${CONTAINERFILE}" "${BUILD_CONTEXT}" 2>&1 | tee "${LOG_FILE}"

echo "==> Creating container ${CONTAINER_NAME}"
docker create \
    --name "${CONTAINER_NAME}" \
    --cpuset-cpus 0-15 \
    --memory 24g \
    -e WORK_DIR=/work/build \
    -e OUT_DIR=/work/out \
    -e CCACHE_DIR=/root/.cache/ccache \
    -v "${SRC_ROOT}:/work/source:ro" \
    -v "${WORK_CACHE}:/work/build" \
    -v "${OUT_DIR}:/work/out" \
    -v "${HOST_CCACHE_DIR}:/root/.cache/ccache" \
    "${IMAGE}" \
    bash "${KERNEL_BUILD_SCRIPT}" \
    >/dev/null
CONTAINER_CREATED=1

echo "==> Running kernel build in ${CONTAINER_NAME} (log: ${LOG_FILE})"
set +e
docker start -a "${CONTAINER_NAME}" 2>&1 | tee -a "${LOG_FILE}"
rc=${PIPESTATUS[0]}
set -e

echo "==> Kernel build finished with exit code ${rc}"
exit "${rc}"
