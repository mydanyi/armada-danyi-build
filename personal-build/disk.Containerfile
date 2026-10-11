# Checked disk-builder image for the armada personal disk unit.
#
# Derives from the exact pinned bootc-image-builder digest so the disk build
# itself is unchanged, and only adds the filesystem/tooling the offline image
# check in build-disk.sh needs but the base does not carry:
#   * dosfstools  -> fsck.fat   (ESP vfat check)
#   * btrfs-progs -> btrfs      (readonly btrfs check of the root subvolume)
#   * jq          -> parses `sfdisk -J` partition-layout.json
#   * file        -> identifies the raw image (also used by the finalize script)
# build-disk.sh builds this as local/armada-personal-disk-builder:checked
# (linux/amd64) and never pulls it.
FROM quay.io/centos-bootc/bootc-image-builder@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b

RUN dnf install -y \
        dosfstools \
        btrfs-progs \
        jq \
        file \
    && dnf clean all \
    && rm -rf /var/cache/dnf/*

# Give osbuild a dedicated bwrap binary path inside this builder image so that
# a host-side AppArmor policy keyed on /usr/bin/bwrap (e.g. Ubuntu's
# /etc/apparmor.d/bwrap-userns-restrict attaching unpriv_bwrap) no longer
# strips the mount/chown capabilities osbuild needs in its bwrap sandbox.
# This only renames the in-image binary and leaves a relative symlink at the
# original path; host AppArmor, profiles, and sysctl are untouched.
# (/usr/sbin is a symlink to /usr/bin on this base, so we only act in /usr/bin.)
RUN mv /usr/bin/bwrap /usr/bin/bwrap-osbuild \
    && ln -s bwrap-osbuild /usr/bin/bwrap