#!/usr/bin/env bash
# Armada personal rootfs build -- Docker runner orchestration.
#
# Assembles the armada bootc rootfs image on the long-lived Docker runner
# (192.168.88.9): the daemon's socket is bind-mounted into the runner
# container, so every docker command below targets that machine, never a local
# engine.
#
# Every package is resolved by content hash exactly the way the official
# `just build` / package CI resolves it: a package is reused from this task's
# own local images if present, else from the published ghcr.io image for that
# hash, and is built from source only when neither exists. The kernel and the
# final rootfs container are the only things built directly here.
#
# There is no fallback to building locally, no docker prune, no host
# installation and no push to any registry. If a pull fails and the fallback
# build fails, the script fails -- success is never fabricated.
#
# Params:
#   TASK_ROOT  (required, absolute)  This build task's server runtime space.
#                                    Provides logs/, work/, output/.
#   SRC_ROOT   (optional, absolute)  Checkout root. Defaults to this script's
#                                    parent's parent (the repository root).
#                                    Identical path on host and runner.
#
# Env:
#   BUILD_ID         (required)  Suffix of the kernel builder container name.
#   ARMADA_VERSION   (required)  Version stamped onto the rootfs image.
#   DOCKER_HOST      Build daemon. Defaults to the Docker socket on the build
#                    server: unix:///var/run/docker.sock, bind-mounted into the
#                    runner container. The runner may override.
#   GITHUB_TOKEN     Optional. When set it is passed to the rootfs build as a
#                    secret (never printed).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SRC_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Positional args override, env vars fall back.
TASK_ROOT="${1:-${TASK_ROOT:-}}"
SRC_ROOT="${2:-${SRC_ROOT:-${DEFAULT_SRC_ROOT}}}"

: "${BUILD_ID:?BUILD_ID is required (container name suffix)}"
: "${TASK_ROOT:?TASK_ROOT is required (absolute path to this task execution space)}"
: "${ARMADA_VERSION:?ARMADA_VERSION is required (version stamped on the rootfs image)}"
[[ "${TASK_ROOT}" == /* ]] || { echo "ERROR: TASK_ROOT must be an absolute path: ${TASK_ROOT}" >&2; exit 2; }
[[ "${SRC_ROOT}" == /* ]] || { echo "ERROR: SRC_ROOT must be an absolute path: ${SRC_ROOT}" >&2; exit 2; }
[[ -f "${SRC_ROOT}/Containerfile" ]] || { echo "ERROR: missing root Containerfile under SRC_ROOT=${SRC_ROOT}" >&2; exit 2; }
[[ -f "${SRC_ROOT}/packages/Containerfile" ]] || { echo "ERROR: missing packages/Containerfile under SRC_ROOT=${SRC_ROOT}" >&2; exit 2; }

# Local Docker socket of the build server (mounted into the runner container);
# the runner may already export DOCKER_HOST.
DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
export DOCKER_HOST
export DOCKER_BUILDKIT=1

LOG_DIR="${TASK_ROOT}/logs"
WORK_DIR="${TASK_ROOT}/work"
OUTPUT_DIR="${TASK_ROOT}/output"
mkdir -p "${LOG_DIR}" "${WORK_DIR}" "${OUTPUT_DIR}"

cd -- "${SRC_ROOT}"

# Official pins: the digest-locked Fedora builder and the FEX guest builder.
# shellcheck source=/dev/null
source packages/toolchain.env
# shellcheck source=/dev/null
source packages/mesa-x86/BASE.env

OFFICIAL_BUILDER_IMAGE="${BUILDER_IMAGE}"
PKG_REGISTRY="ghcr.io/armada-os/armada/pkg"

# Prefer the pre-warmed Fedora 44 dependency layers of an existing local
# builder image; fall back to the official digest-pinned Fedora when absent.
# fedora-builder.Containerfile drops that image's stale sources/RPMs, so they
# can never substitute for the current checkout's sources.
CACHED_BUILDER_PARENT="local/armada-gamescope-builder:y700-20261009-pr665-a17f4c2b"
PERSONAL_BUILDER_IMAGE="local/armada-personal-fedora-deps:44"
PKG_BUILDER_IMAGE="${OFFICIAL_BUILDER_IMAGE}"
if docker image inspect "${CACHED_BUILDER_PARENT}" >/dev/null 2>&1; then
    echo "==> Reusing Fedora 44 deps from ${CACHED_BUILDER_PARENT} -> ${PERSONAL_BUILDER_IMAGE}"
    docker build \
        --platform linux/arm64 \
        --build-arg "BUILDER_PARENT=${CACHED_BUILDER_PARENT}" \
        --tag "${PERSONAL_BUILDER_IMAGE}" \
        -f "${SCRIPT_DIR}/fedora-builder.Containerfile" \
        "${SCRIPT_DIR}" \
        2>&1 | tee "${LOG_DIR}/fedora-builder.log"
    PKG_BUILDER_IMAGE="${PERSONAL_BUILDER_IMAGE}"
else
    echo "==> No cached Fedora deps builder; using official ${OFFICIAL_BUILDER_IMAGE}"
fi

REFS_FILE="${WORK_DIR}/package-refs.env"
: > "${REFS_FILE}"
rootargs=()

for dir in "${SRC_ROOT}"/packages/*/; do
    pkg="$(basename "${dir}")"
    [ -f "${dir}/build.sh" ] || continue

    hash="$(bash "${SRC_ROOT}/packages/package-hash.sh" "${pkg}")"
    localref="localhost/armada-personal/pkg/${pkg}:${hash}"
    officialref="${PKG_REGISTRY}/${pkg}:${hash}"

    # mesa-x86/mesa-android/lepton build for the x86 guests (and FEX), so they
    # take the official x86 Fedora builder. The personal deps builder is ARM64,
    # so those three must never inherit it -- only the ARM64 packages may.
    pkg_builder="${PKG_BUILDER_IMAGE}"
    case "${pkg}" in
        mesa-x86 | mesa-android | lepton)
            platform="linux/amd64"
            pkg_builder="${OFFICIAL_BUILDER_IMAGE}"
            ;;
        *) platform="linux/arm64" ;;
    esac

    # Same VAR transformation the Justfile's `build` recipe uses.
    var="$(printf '%s' "${pkg}" | tr '[:lower:]-' '[:upper:]_')_REF"

    selected=""
    if docker image inspect "${localref}" >/dev/null 2>&1; then
        selected="${localref}"
        echo "==> ${pkg}: local ${localref}"
    elif docker pull --platform "${platform}" "${officialref}" >"${LOG_DIR}/pull-${pkg}.log" 2>&1; then
        selected="${officialref}"
        echo "==> ${pkg}: reusing published ${officialref} (unmodified; log: logs/pull-${pkg}.log)"
    else
        echo "==> ${pkg}: nothing local or published for ${hash}; building from source"
        if [ "${pkg}" = "kernel" ]; then
            # Kernel goes through the existing personal-build/build-kernel.sh,
            # then its verified artifacts are packed into a scratch image that
            # holds only /kernel/* -- matching the official out-kernel layout.
            bash "${SCRIPT_DIR}/build-kernel.sh" "${TASK_ROOT}" "${SRC_ROOT}" \
                2>&1 | tee "${LOG_DIR}/kernel-build.log"
            KERNEL_OUT="${TASK_ROOT}/output/kernel"
            ( cd "${KERNEL_OUT}" && sha256sum -c ./*.sha256 )
            KERNEL_DOCKERFILE="${WORK_DIR}/kernel.Dockerfile"
            cat > "${KERNEL_DOCKERFILE}" <<'EOF'
FROM scratch
COPY . /kernel/
EOF
            docker build \
                --platform linux/arm64 \
                -f "${KERNEL_DOCKERFILE}" \
                --tag "${localref}" \
                "${KERNEL_OUT}"
        else
            docker build \
                -f "${SRC_ROOT}/packages/Containerfile" \
                --target "out-${pkg}" \
                --platform "${platform}" \
                --build-arg "BUILDER_IMAGE=${pkg_builder}" \
                --build-arg "GUEST_BUILDER_IMAGE=${GUEST_BUILDER_IMAGE}" \
                --tag "${localref}" \
                "${SRC_ROOT}/packages" \
                2>&1 | tee "${LOG_DIR}/pkg-${pkg}.log"
        fi
        selected="${localref}"
    fi

    echo "${var}=${selected}" >> "${REFS_FILE}"
    rootargs+=("--build-arg" "${var}=${selected}")
done

# `just build` refuses to proceed unless every ARG *_REF in the root
# Containerfile resolved to exactly one image; keep that contract so a package
# can never be silently dropped from the rootfs.
expected="$(grep -c '^ARG [A-Z0-9_]*_REF$' "${SRC_ROOT}/Containerfile" || true)"
got="$(wc -l < "${REFS_FILE}")"
[ "${expected}" -eq "${got}" ] || { echo "Containerfile wants ${expected} refs, resolved ${got}" >&2; exit 1; }

SECRET_ARGS=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
    SECRET_ARGS+=("--secret" "id=GITHUB_TOKEN,env=GITHUB_TOKEN")
fi

ROOTFS_REF="localhost/armada-personal:${ARMADA_VERSION}"
ROOTFS_LOG="${LOG_DIR}/rootfs.log"

echo "==> Building ${ROOTFS_REF} (log: ${ROOTFS_LOG})"
docker build \
    --platform linux/arm64 \
    --target armada-rootfs \
    -f "${SRC_ROOT}/Containerfile" \
    --build-arg "ARMADA_VERSION=${ARMADA_VERSION}" \
    "${rootargs[@]}" \
    ${SECRET_ARGS[@]+"${SECRET_ARGS[@]}"} \
    --tag "${ROOTFS_REF}" \
    "${SRC_ROOT}" \
    2>&1 | tee "${ROOTFS_LOG}"

# Hand-off artifacts for the next unit, plus a record of the exact image built.
echo "${ROOTFS_REF}" > "${WORK_DIR}/rootfs-ref.txt"
docker image inspect "${ROOTFS_REF}" > "${OUTPUT_DIR}/rootfs-inspect.json"
docker save -o "${WORK_DIR}/rootfs.tar" "${ROOTFS_REF}"

echo "==> Done: ${ROOTFS_REF}"
