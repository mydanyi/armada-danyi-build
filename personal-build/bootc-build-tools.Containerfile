ARG ROOTFS_REF

FROM --platform=linux/amd64 quay.io/fedora/fedora-bootc@sha256:560296332544e7654fe6d8f789f74ee7c596a07326bc388a3f761686d595d93e AS native-tools
RUN set -e; \
    mkdir -p /native/bin /native/lib; \
    cp /usr/bin/btrfs /usr/bin/bwrap /native/bin/; \
    ldd /usr/bin/btrfs /usr/bin/bwrap \
      | awk '/=> \// { print $3 }' \
      | sort -u \
      | while read -r lib; do cp -L "$lib" /native/lib/"${lib##*/}"; done; \
    cp -L /lib64/ld-linux-x86-64.so.2 /native/lib/

FROM --platform=linux/arm64 ${ROOTFS_REF}
COPY --from=native-tools /native /usr/libexec/armada-native-tools
COPY native-tool-wrapper /usr/libexec/armada-native-tools/tool-wrapper
RUN set -e; \
    chmod 0755 /usr/libexec/armada-native-tools/tool-wrapper; \
    rm -f /usr/bin/btrfs /usr/bin/bwrap; \
    ln -s /usr/libexec/armada-native-tools/tool-wrapper /usr/bin/btrfs; \
    ln -s /usr/libexec/armada-native-tools/tool-wrapper /usr/bin/bwrap

# Build-only file locks avoid native/ARM Podman shared-memory ABI conflicts.
RUN set -e; \
    mkdir -p /etc/containers/containers.conf.d; \
    printf '[engine]\nlock_type="file"\n' > /etc/containers/containers.conf.d/99-armada-build.conf
