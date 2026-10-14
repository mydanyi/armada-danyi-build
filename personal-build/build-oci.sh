#!/bin/bash
set -euo pipefail

# build-oci.sh -- package a personal-build rootfs.tar into an OCI archive.
#
# Usage: build-oci.sh TASK_ROOT SRC_ROOT
#   TASK_ROOT : absolute task directory; build-rootfs.sh must already have
#               written TASK_ROOT/work/rootfs.tar and TASK_ROOT/work/rootfs-ref.txt
#   SRC_ROOT  : repository source root (personal-build assets live here)
#
# Required environment:
#   BUILD_ID       : unique build id, used to name the throwaway container
#   ARMADA_VERSION : armada version baked into the image tag and labels
#
# Outputs (under TASK_ROOT/output):
#   armada-<ARMADA_VERSION>.oci.tar : OCI archive of the image
#   oci-image-info.json             : skopeo inspect JSON, verified below
#
# The heavy work (docker-archive -> oci-archive copy and inspect) runs inside the
# existing tool image local/armada-personal-disk-builder:checked. This script
# only wires the mounts and validates the result. No registry push, no network.

usage() { echo "usage: build-oci.sh TASK_ROOT SRC_ROOT" >&2; }

TASK_ROOT="${1:-}"
SRC_ROOT="${2:-}"
[ -n "${TASK_ROOT}" ] && [ -n "${SRC_ROOT}" ] || { usage; exit 2; }

: "${BUILD_ID:?BUILD_ID is required}"
: "${ARMADA_VERSION:?ARMADA_VERSION is required}"

case "${TASK_ROOT}" in
    /*) ;;
    *) echo "ERROR: TASK_ROOT must be an absolute path: ${TASK_ROOT}" >&2; exit 2 ;;
esac

# ARMADA_VERSION becomes a docker tag, an archive filename and a JSON label;
# restrict it to a safe alphanumeric-plus '.', '-', '_' set.
case "${ARMADA_VERSION}" in
    *[!A-Za-z0-9._-]*) echo "ERROR: unsafe ARMADA_VERSION: ${ARMADA_VERSION}" >&2; exit 2 ;;
esac

WORK="${TASK_ROOT}/work"
INPUT_TAR="${WORK}/rootfs.tar"
REF_FILE="${WORK}/rootfs-ref.txt"
OUT_DIR="${TASK_ROOT}/output"
OUT_OCI="${OUT_DIR}/armada-${ARMADA_VERSION}.oci.tar"
OUT_INFO="${OUT_DIR}/oci-image-info.json"

[ -f "${INPUT_TAR}" ] || { echo "ERROR: missing ${INPUT_TAR} (run build-rootfs.sh first)" >&2; exit 1; }
[ -f "${REF_FILE}" ] || { echo "ERROR: missing ${REF_FILE} (run build-rootfs.sh first)" >&2; exit 1; }

mkdir -p "${OUT_DIR}"

CONTAINER="armada-personal-oci-${BUILD_ID}"
IMAGE="local/armada-personal-disk-builder:checked"
OCI_BASENAME="armada-${ARMADA_VERSION}.oci.tar"

docker run --rm \
    --name "${CONTAINER}" \
    --platform linux/amd64 \
    --cpus 4 --memory 4g \
    --network none \
    --entrypoint /bin/bash \
    -v "${WORK}:/input:ro" \
    -v "${OUT_DIR}:/output" \
    "${IMAGE}" \
    -c '
        set -euo pipefail
        OCI_NAME="$1"
        VERSION="$2"
        skopeo copy \
            --format oci \
            "docker-archive:/input/rootfs.tar" \
            "oci-archive:/output/${OCI_NAME}:${VERSION}"
        skopeo inspect "oci-archive:/output/${OCI_NAME}:${VERSION}" \
            > /output/oci-image-info.json
        arch="$(jq -r ".Architecture"       /output/oci-image-info.json)"
        os="$(jq -r ".Os"                   /output/oci-image-info.json)"
        bootc="$(jq -r ".Labels[\"containers.bootc\"]" /output/oci-image-info.json)"
        ver="$(jq -r ".Labels[\"org.opencontainers.image.version\"]" /output/oci-image-info.json)"
        [ "${arch}"  = "arm64"   ] || { echo "ERROR: Architecture=${arch} != arm64" >&2; exit 1; }
        [ "${os}"    = "linux"   ] || { echo "ERROR: Os=${os} != linux" >&2; exit 1; }
        [ "${bootc}" = "1"       ] || { echo "ERROR: containers.bootc=${bootc} != 1" >&2; exit 1; }
        [ "${ver}"   = "${VERSION}" ] || { echo "ERROR: image.version=${ver} != ${VERSION}" >&2; exit 1; }
    ' _ "${OCI_BASENAME}" "${ARMADA_VERSION}"

# The verified artifacts must exist and be non-empty on the host side too.
[ -s "${OUT_OCI}" ] || { echo "ERROR: OCI archive missing or empty: ${OUT_OCI}" >&2; exit 1; }
[ -s "${OUT_INFO}" ] || { echo "ERROR: inspect JSON missing or empty: ${OUT_INFO}" >&2; exit 1; }

echo "OCI archive: ${OUT_OCI}"
echo "Image info : ${OUT_INFO}"
echo "Verified   : Architecture=arm64 Os=linux containers.bootc=1 version=${ARMADA_VERSION}"
