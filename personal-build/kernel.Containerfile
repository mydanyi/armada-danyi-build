# x86_64 build runtime for cross-compiling the aarch64 armada kernel.
# Only the toolchain lives here; source, work, out and ccache are bind-mounted
# by personal-build/build-kernel.sh. Nothing is baked in beyond apt packages.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        bc \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        dwarves \
        cpio \
        rsync \
        curl \
        ca-certificates \
        xz-utils \
        zstd \
        kmod \
        ccache \
        python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["bash"]
