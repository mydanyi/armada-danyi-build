#!/bin/bash
set -euxo pipefail

# Personal (NAS-sourced) Decky plugins, preinstalled into the image location the
# official armada-decky-sync seeds from. No new boot service is added; the
# existing armada-decky-sync copies /usr/share/decky-plugins/* into the user's
# homebrew tree.
#
# Public archive attachments are downloaded from the public GitHub releases;
# private archive attachments ship inside the private source tree as bundled
# assets. Either way every archive is pinned by SHA-256 in
# personal-build/plugins.lock.json. Each package already carries a top-level
# directory named after the plugin, so its zip extracts straight into
# /usr/share/decky-plugins without an extra nesting level.
#
# Only upstream release files (licenses included) are installed: no
# subscriptions, personal configuration, commercial DLLs, or per-game configs.

work="$(mktemp -d /tmp/armada-personal-plugins.XXXXXX)"
trap 'rm -rf "${work}"' EXIT

install -d -m 0755 /usr/share/decky-plugins

PLUGIN_LOCK=/ctx/personal-build/plugins.lock.json \
PLUGIN_DEST=/usr/share/decky-plugins \
PLUGIN_WORK="${work}" \
python3 - <<'PY'
import hashlib
import json
import os
import shutil
import urllib.request
import zipfile

LOCK = os.environ["PLUGIN_LOCK"]
DEST = os.environ["PLUGIN_DEST"]
WORK = os.environ["PLUGIN_WORK"]
REQUIRED_FILES = ("plugin.json", "main.py", "dist/index.js")


def fetch(url, path):
    request = urllib.request.Request(url, headers={"User-Agent": "armada-personal-build"})
    with urllib.request.urlopen(request) as response, open(path, "wb") as out:
        shutil.copyfileobj(response, out)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def members(archive):
    for info in archive.infolist():
        name = info.filename
        if name.startswith("/") or os.path.isabs(name):
            raise SystemExit(f"unsafe absolute path in archive: {name}")
        if any(part == ".." for part in name.split("/")):
            raise SystemExit(f"unsafe relative path in archive: {name}")
        yield info


def extract(archive, dest):
    # zipfile.extract() drops Unix permissions, so apply the mode recorded in
    # each ZipInfo's external_attr (high 16 bits) to honour executable bits.
    for info in members(archive):
        target = os.path.join(dest, info.filename)
        if info.is_dir():
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with archive.open(info) as src, open(target, "wb") as out:
            shutil.copyfileobj(src, out)
        mode = (info.external_attr >> 16) & 0o777
        if mode:
            os.chmod(target, mode)


def root_owned(path):
    os.chown(path, 0, 0)
    for dirpath, _dirnames, filenames in os.walk(path):
        os.chown(dirpath, 0, 0)
        for filename in filenames:
            os.chown(os.path.join(dirpath, filename), 0, 0)


def ensure_executable(plugin_dir, wanted):
    root = os.path.join(DEST, plugin_dir)
    preferred = os.path.join(root, "bin", wanted)
    if os.path.isfile(preferred):
        candidates = [preferred]
    else:
        candidates = [
            os.path.join(dirpath, filename)
            for dirpath, _dirnames, filenames in os.walk(root)
            for filename in filenames
            if filename == wanted
        ]
    if not candidates:
        raise SystemExit(f"expected {wanted} inside {plugin_dir} but found none")
    for path in candidates:
        os.chmod(path, 0o755)
        print(f"marked executable: {path}")


with open(LOCK, encoding="utf-8") as handle:
    plugins = json.load(handle)

if not isinstance(plugins, list) or not plugins:
    raise SystemExit(f"expected a non-empty array in {LOCK}")

for plugin in plugins:
    name = plugin["name"]
    directory = plugin["directory"]
    archive_path = os.path.join(WORK, f"{directory}.zip")

    print(f"installing {name} {plugin['version']}")
    if plugin.get("archive"):
        shutil.copyfile(os.path.join("/ctx", plugin["archive"]), archive_path)
        print(f"using bundled package: {plugin['archive']}")
    else:
        fetch(plugin["url"], archive_path)

    actual = sha256(archive_path)
    expected = plugin["sha256"].lower()
    if actual != expected:
        raise SystemExit(f"sha256 mismatch for {name}: {actual} != {expected}")
    print(f"sha256 verified: {actual}")

    with zipfile.ZipFile(archive_path) as archive:
        extract(archive, DEST)

    plugin_root = os.path.join(DEST, directory)
    for required in REQUIRED_FILES:
        path = os.path.join(plugin_root, required)
        if not os.path.isfile(path):
            raise SystemExit(f"missing {required} in {name} ({directory})")

    root_owned(plugin_root)

    # DeckyClash's proxy core must stay executable for its tun service.
    if directory == "DeckyClash":
        ensure_executable(directory, "mihomo")

print("personal plugins installed")
PY

# Keep the resolved lock file in the image for traceability.
install -Dpm 0644 /ctx/personal-build/plugins.lock.json \
    /usr/share/armada/personal-build/plugins.lock.json
