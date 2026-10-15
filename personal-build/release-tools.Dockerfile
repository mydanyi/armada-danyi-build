# 7-Zip 26.04 Linux x64 — official upstream release asset.
# Source: https://github.com/ip7z/7zip/releases/download/26.04/7z2604-linux-x64.tar.xz
# SHA256 (archive): fc0327ba27e89bd086cf426dff17d77de582953cdbbc10a6576540a06853ffcd
FROM local/armada-personal-disk-builder:checked

COPY personal-build/tools/7z2604-linux-x64.tar.xz /opt/7zip/archive.tar.xz

RUN set -eux; \
    cd /opt/7zip; \
    echo "fc0327ba27e89bd086cf426dff17d77de582953cdbbc10a6576540a06853ffcd  archive.tar.xz" | sha256sum -c -; \
    tar -xJf archive.tar.xz; \
    rm -f archive.tar.xz; \
    test -n "$(find /opt/7zip -type f -iname 'license*' | head -n1)"; \
    ln -sf "$(find /opt/7zip -type f -name 7zz | head -n1)" /usr/local/bin/7zz; \
    chmod +x /usr/local/bin/7zz; \
    /usr/local/bin/7zz >/dev/null
