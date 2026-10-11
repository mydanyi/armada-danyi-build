# Long-lived GitHub Actions self-hosted runner host container for the
# mydanyi/armada-personal-build private repo.
#
# Runs on the x86_64 Docker host at 192.168.88.9. This image only carries the
# runner distribution plus the tools jobs need; registration state lives in the
# /runner bind mount, so the same image can (re)register without a rebuild.
#
# The Docker socket is mounted in by the operator and only this container uses
# it; dockerd itself is NOT started here.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        curl \
        ca-certificates \
        jq \
        python3 \
        python3-yaml \
        rsync \
        openssh-client \
        unzip \
        xz-utils \
        gzip \
        tar \
        sudo \
        docker.io \
        docker-buildx \
        libicu74 \
        libssl3 \
        zlib1g \
        libkrb5-3 \
    && rm -rf /var/lib/apt/lists/*

# Pinned runner release; the download is verified against this checksum, then
# unpacked to a pristine distribution directory and the tarball removed so it
# never stays in the image layer.
ARG RUNNER_VERSION=2.338.0
ARG RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
ARG RUNNER_SHA256="af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32"

RUN set -eux; \
    curl -fsSL -o "/tmp/${RUNNER_TARBALL}" \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"; \
    echo "${RUNNER_SHA256}  /tmp/${RUNNER_TARBALL}" | sha256sum -c -; \
    mkdir -p /opt/runner-dist; \
    tar -xzf "/tmp/${RUNNER_TARBALL}" -C /opt/runner-dist; \
    rm -f "/tmp/${RUNNER_TARBALL}"

# The runner refuses to run as root unless explicitly allowed.
ENV RUNNER_ALLOW_RUNASROOT=1

# /runner is a persistent bind mount holding runner config and workspace state.
WORKDIR /runner

COPY runner-entrypoint.sh /usr/local/bin/armada-runner-entrypoint.sh
RUN chmod +x /usr/local/bin/armada-runner-entrypoint.sh

ENTRYPOINT ["bash", "/usr/local/bin/armada-runner-entrypoint.sh"]
CMD ["./run.sh"]
