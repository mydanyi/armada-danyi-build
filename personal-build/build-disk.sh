#!/usr/bin/env bash
# Armada personal disk build — Docker runner orchestration.
#
# Turns the rootfs unit's image into a flashable disk image on the long-lived
# Docker runner (192.168.88.9): the pinned BIB produces output/image/disk.raw,
# the official post_process scripts stage the ROCKNIX ABL /KERNEL and finalize
# the image (MBR + ABL + gzip), and an inline offline check verifies the
# freshly-built image between those two steps before it is compressed.
#
# BIB runs with --build-container pointing at a local ARM64 build environment
# that replaces btrfs/bwrap with native tools while the ARM64 installer remains
# under qemu-user. The target payload is unchanged.
#
# Everything runs inside the pinned BIB container with an exclusive overlay
# containers-storage cache under this task's runtime space: the host's global
# podman storage is never mounted or touched, nothing is pruned, and no host
# configuration changes. There is no fallback to building locally and nothing
# is pushed to a container registry: the NAS stays the source and delivery
# authority and the install/upgrade artifacts are also published to a GitHub
# Release. Every output of this script lives under TASK_ROOT.
#
# Params:
#   TASK_ROOT  (required, absolute)  This build task's server runtime space.
#                                    Provides logs/, work/ (rootfs.tar and
#                                    rootfs-ref.txt from the rootfs unit),
#                                    output/ and cache/.
#   SRC_ROOT   (optional, absolute)  Checkout root. Defaults to this script's
#                                    parent's parent (the repository root).
#                                    Identical path on host and runner.
#
# Env:
#   BUILD_ID         (required)  Suffix of the disk builder container name.
#   ARMADA_VERSION   (required)  Version stamped onto the output image name.
#   DOCKER_HOST      Build daemon. Defaults to the Docker socket on the build
#                    server: unix:///var/run/docker.sock, bind-mounted into the
#                    runner container. The runner may override.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SRC_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Positional args override, env vars fall back.
TASK_ROOT="${1:-${TASK_ROOT:-}}"
SRC_ROOT="${2:-${SRC_ROOT:-${DEFAULT_SRC_ROOT}}}"

: "${BUILD_ID:?BUILD_ID is required (container name suffix)}"
: "${TASK_ROOT:?TASK_ROOT is required (absolute path to this task execution space)}"
: "${ARMADA_VERSION:?ARMADA_VERSION is required (version stamped onto the output image)}"
[[ "${TASK_ROOT}" == /* ]] || { echo "ERROR: TASK_ROOT must be an absolute path: ${TASK_ROOT}" >&2; exit 2; }
[[ "${SRC_ROOT}" == /* ]] || { echo "ERROR: SRC_ROOT must be an absolute path: ${SRC_ROOT}" >&2; exit 2; }

# Checked disk-builder image this unit runs the BIB build and the offline image
# check inside. It is built locally from disk.Containerfile, which derives from
# the pinned bootc-image-builder digest (linux/amd64) -- carrying the tools this
# unit needs (/usr/bin/bootc-image-builder, podman, sudo, pigz, ostree, crun)
# plus the filesystem/tooling the offline check requires (dosfstools,
# btrfs-progs, jq, file). It is never pulled: it only ever exists locally.
BIB_IMAGE="local/armada-personal-disk-builder:checked"
BIB_BUILD_REF="localhost/armada-personal-bootc-tools:${BUILD_ID}"

# Local Docker socket of the build server (mounted into the runner container);
# the runner may already export DOCKER_HOST.
DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
export DOCKER_HOST

LOG_DIR="${TASK_ROOT}/logs"
WORK_DIR="${TASK_ROOT}/work"
OUTPUT_DIR="${TASK_ROOT}/output"
BIB_STORAGE="${TASK_ROOT}/cache/bib-overlay-storage"
LOG_FILE="${LOG_DIR}/disk.log"

ROOTFS_TAR="${WORK_DIR}/rootfs.tar"
ROOTFS_REF_FILE="${WORK_DIR}/rootfs-ref.txt"

mkdir -p "${LOG_DIR}" "${WORK_DIR}" "${OUTPUT_DIR}" "${BIB_STORAGE}"

# Inputs handed over by the rootfs unit.
[[ -f "${ROOTFS_TAR}" ]] \
    || { echo "ERROR: missing rootfs image ${ROOTFS_TAR} (run the rootfs unit first)" >&2; exit 2; }
[[ -f "${ROOTFS_REF_FILE}" ]] \
    || { echo "ERROR: missing ${ROOTFS_REF_FILE} (run the rootfs unit first)" >&2; exit 2; }

# Official scripts and the BIB disk config this unit depends on.
[[ -f "${SRC_ROOT}/post_process/make-bootimg.sh" ]] \
    || { echo "ERROR: missing ${SRC_ROOT}/post_process/make-bootimg.sh" >&2; exit 2; }
[[ -f "${SRC_ROOT}/post_process/finalize-armada-image.sh" ]] \
    || { echo "ERROR: missing ${SRC_ROOT}/post_process/finalize-armada-image.sh" >&2; exit 2; }
[[ -f "${SRC_ROOT}/disk_config/disk.toml" ]] \
    || { echo "ERROR: missing ${SRC_ROOT}/disk_config/disk.toml" >&2; exit 2; }

# The image BIB builds the disk from is whatever the rootfs unit produced.
IMAGE_NAME="$(tr -d '[:space:]' < "${ROOTFS_REF_FILE}")"
[[ -n "${IMAGE_NAME}" ]] \
    || { echo "ERROR: ${ROOTFS_REF_FILE} is empty" >&2; exit 2; }

CONTAINER_NAME="armada-personal-disk-${BUILD_ID}"
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

# ---------- the script that runs inside the BIB container ------------------
INNER_SCRIPT="$(cat <<'INNER_EOF'
#!/bin/bash
# Runs INSIDE the pinned bootc-image-builder container.
set -euo pipefail

: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${ARMADA_VERSION:?ARMADA_VERSION is required}"
: "${BIB_BUILD_REF:?BIB_BUILD_REF is required}"

RAW=/output/image/disk.raw

# Isolate containers/storage inside this container on this task's exclusive
# overlay store (the mounted /var/lib/containers/storage). BIB requires the
# overlay driver -- vfs is incompatible -- and this store is independent of the
# earlier vfs cache. BIB and every podman invocation below inherit this through
# the environment, so nothing here ever reads the host's global podman storage.
export CONTAINERS_STORAGE_CONF=/work/containers-storage.conf
cat >"${CONTAINERS_STORAGE_CONF}" <<'STORAGE_CONF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
STORAGE_CONF

# Load the rootfs unit's image (a `docker save` tarball) into that storage.
podman --storage-driver=overlay load -i /work/rootfs.tar

# Load the ARM64 build environment containing native filesystem/sandbox tools.
podman --storage-driver=overlay load -i /work/disk-builder.tar

# BIB's osbuild store must exist before the build; without it BIB fails with
# "chcon: cannot access '/work/osbuild-store': No such file or directory".
mkdir -p /work/osbuild-store

# Build the raw ARM64 disk. /config.toml is read automatically. --build-container
# runs the build in the loaded ARM64 environment (native btrfs/bwrap) instead of
# emulating the btrfs ioctls; the target payload is unchanged.
/usr/bin/bootc-image-builder build "${IMAGE_NAME}" \
    --type raw \
    --target-arch arm64 \
    --rootfs btrfs \
    --build-container "${BIB_BUILD_REF}" \
    --output /output \
    --store /work/osbuild-store \
    --use-librepo=true

[ -s "${RAW}" ] || { echo "ERROR: BIB produced no raw image at ${RAW}" >&2; exit 1; }
echo "==> BIB raw image size: $(stat -c '%s' "${RAW}") bytes"

# Stage the ROCKNIX ABL /KERNEL on the ESP (official post-process step). The
# official script takes the raw image path as its argument; invoked via bash so
# it does not depend on the checkout's executable bit.
bash /source/post_process/make-bootimg.sh "${RAW}"

# ---------- offline verification of the freshly-built image ---------------
CHECK_TMP="$(mktemp -d /work/check.XXXXXX)"
MNT="${CHECK_TMP}/mnt"
mkdir -p "${MNT}/p1" "${MNT}/p2" "${MNT}/p3"
LOOP=""

# Only ever unmount our own mounts and detach our own loop.
cleanup_mounts() {
    local rc=$?
    trap - EXIT INT TERM
    umount "${MNT}/p3" 2>/dev/null || true
    umount "${MNT}/p2" 2>/dev/null || true
    umount "${MNT}/p1" 2>/dev/null || true
    if [ -n "${LOOP}" ]; then
        losetup -d "${LOOP}" 2>/dev/null || true
    fi
    exit "${rc}"
}
trap cleanup_mounts EXIT INT TERM

# Only ever touch the loop/the image this run produced.
LOOP="$(losetup -fP --show "${RAW}")"

# Record the partition layout BIB produced.
sfdisk -J "${LOOP}" > /output/partition-layout.json

mount "${LOOP}p1" "${MNT}/p1"
mount "${LOOP}p2" "${MNT}/p2"
# The Btrfs default subvolume (ID 5) is the top level and holds only the
# 'root' subvolume; the deployment lives under /root, so mount that subvolume
# explicitly (matching the kernel's rootflags=subvol=/root).
mount -o subvol=/root "${LOOP}p3" "${MNT}/p3"
ROOT="${MNT}/p3"

shopt -s nullglob

# The single ostree deployment. `*.0` only matches the deployment directory --
# the sibling "<checksum>.0.origin" file is never treated as a directory.
deploy_dirs=()
for d in "${ROOT}/ostree/deploy/"*/deploy/*.0; do
    [ -d "${d}" ] || continue
    deploy_dirs+=("${d}")
done
if [ "${#deploy_dirs[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one ostree deployment, found ${#deploy_dirs[@]}:" >&2
    printf '  %s\n' "${deploy_dirs[@]}" >&2
    exit 1
fi
DEPLOY="${deploy_dirs[0]}"
[ ! -e "${DEPLOY}/usr/libexec/armada-native-tools" ] || { echo "ERROR: build-only native tools leaked into the target deployment" >&2; exit 1; }
ORIGIN="${DEPLOY}.origin"

# Decky plugins: the two official ones plus the three NAS-sourced ones.
PLUGINS_ROOT="${DEPLOY}/usr/share/decky-plugins"
for plugin in "armada-control" "armada-store" "armada-installer" "LSFG-VK ARM64" "DeckyClash"; do
    for f in plugin.json main.py dist/index.js; do
        [ -f "${PLUGINS_ROOT}/${plugin}/${f}" ] \
            || { echo "ERROR: Decky plugin ${plugin} is missing ${f}" >&2; exit 1; }
    done
done

# DeckyClash's proxy core must ship executable.
mihomo="${PLUGINS_ROOT}/DeckyClash/bin/mihomo"
if [ ! -f "${mihomo}" ]; then
    mihomo="$(find "${PLUGINS_ROOT}/DeckyClash" -type f -name mihomo -print -quit)"
fi
if [ -z "${mihomo}" ] || [ ! -x "${mihomo}" ]; then
    echo "ERROR: DeckyClash mihomo core is missing or not executable" >&2
    exit 1
fi

# Exactly one kernel under /usr/lib/modules, carrying the Armada build stamp.
kernel_dirs=( "${DEPLOY}"/usr/lib/modules/*/ )
if [ "${#kernel_dirs[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one kernel under ${DEPLOY}/usr/lib/modules, found ${#kernel_dirs[@]}" >&2
    exit 1
fi
KDIR="${kernel_dirs[0]}"
for f in vmlinuz initramfs.img .armada-source; do
    [ -f "${KDIR}/${f}" ] || { echo "ERROR: kernel artifact missing: ${KDIR}/${f}" >&2; exit 1; }
done

# Steam gaming-mode pinyin: unit, launcher, dconf profile, and the ibus binary.
[ -f "${DEPLOY}/usr/lib/systemd/user/armada-steam-pinyin.service" ] \
    || { echo "ERROR: steam-pinyin unit missing" >&2; exit 1; }
[ -x "${DEPLOY}/usr/libexec/armada/steam-pinyin" ] \
    || { echo "ERROR: steam-pinyin launcher missing or not executable" >&2; exit 1; }
[ -f "${DEPLOY}/usr/share/armada/ibus/profile" ] \
    || { echo "ERROR: ibus dconf profile missing" >&2; exit 1; }
[ -x "${DEPLOY}/usr/bin/ibus" ] \
    || { echo "ERROR: /usr/bin/ibus missing" >&2; exit 1; }

# Resolved personal-plugin lock kept in the image for traceability.
[ -f "${DEPLOY}/usr/share/armada/personal-build/plugins.lock.json" ] \
    || { echo "ERROR: plugins.lock.json missing from the image" >&2; exit 1; }

# Verify the ostree repository object store.
ostree fsck --repo="${ROOT}/ostree/repo"

# The BIB image records the local build reference (a localhost image that no
# flashed device can pull). This is a personal build: its OTA path is the 单翼版
# (danyi) update channel, which imports an OCI image from a GitHub Release (the
# armada-danyi-update helper performs the import). The deployment is
# deliberately NOT repointed at the official Beta channel -- doing so would let a
# later official update replace this customised system layer without an explicit
# channel choice.
[ -f "${ORIGIN}" ] || { echo "ERROR: deployment origin missing: ${ORIGIN}" >&2; exit 1; }
original_ref="$(sed -n 's/^container-image-reference=//p' "${ORIGIN}")"
[ -n "${original_ref}" ] \
    || { echo "ERROR: no container-image-reference in ${ORIGIN}" >&2; exit 1; }

cat > /output/update-source.txt <<EOF
This disk image's single ostree deployment carries its bootc update source.

Original container-image-reference (recorded by the local build):
  ${original_ref}

This is a personal build and is NOT repointed at the official Beta channel:
doing so would let a later official update replace this customised system
layer. Updates are instead applied through the 单翼版 (danyi) channel, which
imports an OCI image from a GitHub Release (the armada-danyi-update helper
performs the import). Both the install and upgrade artifacts are published to a
GitHub Release while the NAS copy is kept as well; nothing is pushed to a
container registry.
EOF

# Checking or repairing needs the partitions unmounted: unmount, then check each
# filesystem on the still-attached loop and require a clean result.
sync
umount "${MNT}/p3"
umount "${MNT}/p2"
umount "${MNT}/p1"

fsck.fat -n "${LOOP}p1" \
    || { echo "ERROR: fsck.fat reported issues on ${LOOP}p1" >&2; exit 1; }

set +e
e2fsck -fn "${LOOP}p2"
e2fsck_rc=$?
set -e
# -fn never writes, so any non-zero status -- including 1, "corrected" -- means
# the filesystem is not clean and must not be silently accepted.
[ "${e2fsck_rc}" -eq 0 ] \
    || { echo "ERROR: e2fsck reported issues on ${LOOP}p2 (exit ${e2fsck_rc})" >&2; exit 1; }

btrfs check --readonly "${LOOP}p3" \
    || { echo "ERROR: btrfs check reported issues on ${LOOP}p3" >&2; exit 1; }

losetup -d "${LOOP}"
LOOP=""
rm -rf "${CHECK_TMP}"

# ---------- official finalize: MBR + ABL + gzip (removes the raw) ---------
# The script only touches this image's own loop device -- never a real disk.
mkdir -p /work/tmp
export OUT="/output/armada-${ARMADA_VERSION}.img.gz"
export GZIP_LEVEL=6
export TMPDIR=/work/tmp
bash /source/post_process/finalize-armada-image.sh "${RAW}"

# Verify the compressed artifact and record its hash.
pigz -t "${OUT}"
( cd /output && sha256sum "$(basename "${OUT}")" > SHA256SUMS.txt )

echo "==> Disk build complete: ${OUT}"
cat /output/SHA256SUMS.txt
INNER_EOF
)"

echo "==> Building checked disk builder image ${BIB_IMAGE}"
docker build \
    --platform linux/amd64 \
    -f "${SCRIPT_DIR}/disk.Containerfile" \
    -t "${BIB_IMAGE}" \
    "${SCRIPT_DIR}"

echo "==> Building ARM64 build environment ${BIB_BUILD_REF}"
docker build \
    --platform linux/arm64 \
    --build-arg "ROOTFS_REF=${IMAGE_NAME}" \
    -f "${SCRIPT_DIR}/bootc-build-tools.Containerfile" \
    -t "${BIB_BUILD_REF}" \
    "${SCRIPT_DIR}"

echo "==> Exporting ${BIB_BUILD_REF} to disk-builder.tar"
docker save -o "${WORK_DIR}/disk-builder.tar" "${BIB_BUILD_REF}"

echo "==> Creating container ${CONTAINER_NAME}"
docker create \
    --name "${CONTAINER_NAME}" \
    --privileged \
    --security-opt apparmor=unconfined \
    --network host \
    --platform linux/amd64 \
    --cpuset-cpus 16-31 \
    --memory 16g \
    --entrypoint /bin/bash \
    -e "IMAGE_NAME=${IMAGE_NAME}" \
    -e "ARMADA_VERSION=${ARMADA_VERSION}" \
    -e "BIB_BUILD_REF=${BIB_BUILD_REF}" \
    -v "${SRC_ROOT}:/source:ro" \
    -v "${WORK_DIR}:/work" \
    -v "${OUTPUT_DIR}:/output" \
    -v "${SRC_ROOT}/disk_config/disk.toml:/config.toml:ro" \
    -v "${BIB_STORAGE}:/var/lib/containers/storage" \
    -v /dev:/dev \
    "${BIB_IMAGE}" \
    -c "${INNER_SCRIPT}" \
    >/dev/null
CONTAINER_CREATED=1

echo "==> Running disk build in ${CONTAINER_NAME} (log: ${LOG_FILE})"
set +e
docker start -a "${CONTAINER_NAME}" 2>&1 | tee "${LOG_FILE}"
rc=${PIPESTATUS[0]}
set -e

echo "==> Disk build finished with exit code ${rc}"
exit "${rc}"
