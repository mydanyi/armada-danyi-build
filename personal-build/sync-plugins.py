#!/usr/bin/env python3
"""Refresh the three standalone Decky plugin releases in the plugin lock.

Usage: python3 personal-build/sync-plugins.py REPO

Reads ``REPO/personal-build/plugins.lock.json`` and asks GitHub for the latest
release of armada-installer, LSFG-VK ARM64 (private repository) and DeckyClash.
Only those three plugins are handled; the other plugins still come from the
upstream source tree.

On success stdout is exactly one JSON object::

    {"updated": ["<name>", ...], "skipped": ["<name>", ...]}

everything else -- including skip reasons -- goes to stderr. Every changed
entry is downloaded into a temporary directory, hashed while streaming and
checked as a plugin ZIP; the lock and the private package copies are only
written once every entry validated, so a failure leaves them byte-identical.
Plugin code is never executed.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

API_BASE = os.environ.get("ARMADA_PLUGIN_API_BASE", "https://api.github.com").rstrip("/")
TIMEOUT_SECONDS = 60

# The only plugins this helper knows about, keyed by their lock entry name.
PLUGINS = {
    "armada-installer": {
        "owner": "mydanyi",
        "repo": "armada-installer",
        "asset": "armada-installer-{version}.zip",
        "private": False,
    },
    "LSFG-VK ARM64": {
        "owner": "mydanyi",
        "repo": "decky-lsfg-vk-arm64",
        "asset": "LSFG-VK-ARM64-{version}-full.zip",
        "private": True,
    },
    "DeckyClash": {
        "owner": "chenx-dust",
        "repo": "DeckyClash",
        "asset": "DeckyClash-full-linux-arm64.zip",
        "private": False,
    },
}

PLUGIN_FILES = ("plugin.json", "main.py", "dist/index.js")
VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+~-]{0,127}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class SyncError(Exception):
    """A real failure: nothing may be written and the caller must not push."""


class SkipPlugin(Exception):
    """This plugin stays at its locked version but the run still succeeds."""


def log(message):
    print(message, file=sys.stderr, flush=True)


def read_token_file(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError as exc:
        log("WARNING: cannot read token file %s: %s" % (path, exc))
        return ""


def find_token():
    """First available read credential, in the documented order."""
    explicit = os.environ.get("ARMADA_PLUGIN_TOKEN_FILE", "")
    candidates = []
    if explicit:
        candidates.append(explicit)
    else:
        base = os.environ.get("ARMADA_EXECUTION_BASE", "")
        if base:
            default = os.path.join(base, "credentials", "plugin-release-read-token")
            if os.path.isfile(default):
                candidates.append(default)
    for path in candidates:
        token = read_token_file(path)
        if token:
            return token
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        token = os.environ.get(name, "").strip()
        if token:
            return token
    return ""


def open_url(url, token="", accept=""):
    request = urllib.request.Request(url)
    request.add_header("User-Agent", "armada-personal-plugin-sync")
    if accept:
        request.add_header("Accept", accept)
    if token:
        # Documented urllib behaviour: an unredirected header is sent with
        # this request only, so a signed redirect to the asset host never
        # carries the token.
        request.add_unredirected_header("Authorization", "Bearer " + token)
    return urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS)


def fetch_release(spec, token):
    url = "%s/repos/%s/%s/releases/latest" % (API_BASE, spec["owner"], spec["repo"])
    label = "%s/%s" % (spec["owner"], spec["repo"])
    try:
        with open_url(url, token=token, accept="application/vnd.github+json") as response:
            payload = response.read()
    except urllib.error.HTTPError as exc:
        if spec["private"] and exc.code in (401, 403, 404):
            raise SkipPlugin(
                "release API is not readable with the available credentials (HTTP %d)" % exc.code
            )
        raise SyncError("%s: release API failed (HTTP %d)" % (label, exc.code))
    except (urllib.error.URLError, OSError) as exc:
        raise SyncError("%s: release API failed: %s" % (label, exc))
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise SyncError("%s: release API returned invalid JSON: %s" % (label, exc))


def version_from_tag(tag):
    version = tag[1:] if tag.startswith("v") else tag
    if not VERSION_RE.fullmatch(version):
        raise SyncError("release tag %r does not produce a safe version" % tag)
    return version


def version_greater(candidate, current):
    """Compare like the seeding code: coreutils ``sort -V`` with '-' as '~'."""
    left = candidate.replace("-", "~")
    right = current.replace("-", "~")
    if left == right:
        return False
    environment = dict(os.environ)
    environment["LC_ALL"] = "C"
    try:
        result = subprocess.run(
            ["sort", "-V"],
            input="%s\n%s\n" % (left, right),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise SyncError("cannot compare versions with sort -V: %s" % exc)
    ordered = result.stdout.splitlines()
    return bool(ordered) and ordered[-1] == left


def asset_sha256(asset):
    digest = asset.get("digest")
    if not isinstance(digest, str) or not digest:
        return ""
    scheme, _, value = digest.partition(":")
    if scheme.lower() != "sha256":
        return ""
    value = value.strip().lower()
    if not SHA256_RE.fullmatch(value):
        raise SyncError("asset digest is not a SHA256 value: %r" % digest)
    return value


def download_asset(spec, asset, token, workdir):
    if spec["private"]:
        url = asset.get("url")
        if not isinstance(url, str) or not url:
            raise SyncError("%s: private asset has no Release Asset API URL" % asset.get("name"))
        response = open_url(url, token=token, accept="application/octet-stream")
    else:
        url = asset.get("browser_download_url")
        if not isinstance(url, str) or not url:
            raise SyncError("%s: asset has no browser download URL" % asset.get("name"))
        response = open_url(url, accept="application/octet-stream")

    target = os.path.join(workdir, asset["name"])
    digest = hashlib.sha256()
    try:
        with response, open(target, "wb") as handle:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                digest.update(chunk)
                handle.write(chunk)
    except (urllib.error.HTTPError, urllib.error.URLError, OSError) as exc:
        raise SyncError("asset download failed: %s" % exc)
    return target, digest.hexdigest()


def validate_zip(path, directory, name):
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
    except (zipfile.BadZipFile, OSError) as exc:
        raise SyncError("%s: downloaded asset is not a readable ZIP: %s" % (name, exc))
    missing = [item for item in PLUGIN_FILES if "%s/%s" % (directory, item) not in names]
    if missing:
        raise SyncError("%s: ZIP is missing %s" % (name, ", ".join(missing)))


def sync_entry(entry, spec, token, workdir):
    """Return (values, archive source, asset name) or (None, None, None)."""
    name = entry["name"]
    if spec["private"] and not token:
        raise SkipPlugin("no read token for the private release repository")

    release = fetch_release(spec, token)
    if release.get("draft"):
        raise SkipPlugin("latest release is a draft")
    if release.get("prerelease"):
        raise SkipPlugin("latest release is a prerelease")

    tag = release.get("tag_name")
    if not isinstance(tag, str) or not tag:
        raise SyncError("%s: release has no tag_name" % name)
    version = version_from_tag(tag)
    asset_name = spec["asset"].format(version=version)

    asset = None
    for candidate in release.get("assets") or []:
        if isinstance(candidate, dict) and candidate.get("name") == asset_name:
            asset = candidate
            break
    if asset is None:
        raise SyncError("%s: release %s has no asset %s" % (name, tag, asset_name))

    remote_digest = asset_sha256(asset)
    locked_version = str(entry.get("version") or "")
    locked_sha = str(entry.get("sha256") or "").lower()

    if version == locked_version:
        if remote_digest and remote_digest == locked_sha:
            log("%s: %s is already locked" % (name, version))
            return None, None, None
        if not remote_digest:
            log("%s: no asset digest published; keeping locked %s" % (name, version))
            return None, None, None
    elif not version_greater(version, locked_version):
        raise SkipPlugin("latest %s is not newer than locked %s" % (version, locked_version))

    directory = entry.get("directory")
    if (
        not isinstance(directory, str)
        or not directory
        or directory in (".", "..")
        or "/" in directory
        or "\\" in directory
    ):
        raise SyncError("%s: lock entry needs a safe directory name" % name)

    archive, actual = download_asset(spec, asset, token, workdir)
    if remote_digest and remote_digest != actual:
        raise SyncError(
            "%s: SHA256 mismatch for %s: expected %s, got %s"
            % (name, asset_name, remote_digest, actual)
        )
    validate_zip(archive, directory, name)

    url = asset.get("browser_download_url") or asset.get("url")
    if not isinstance(url, str) or not url:
        raise SyncError("%s: asset %s has no download URL" % (name, asset_name))

    values = {"version": version, "url": url, "sha256": actual}
    if spec["private"]:
        values["archive"] = "personal-build/plugin-assets/" + asset_name
        return values, archive, asset_name
    return values, None, asset_name


def apply_values(entry, values):
    for key in ("version", "url", "sha256", "archive"):
        if key in values:
            entry[key] = values[key]


def store_archive(pb, asset_name, source):
    assets = os.path.join(pb, "plugin-assets")
    os.makedirs(assets, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".asset-", dir=assets)
    os.close(fd)
    try:
        shutil.copyfile(source, temporary)
        os.replace(temporary, os.path.join(assets, asset_name))
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def write_lock(lock_path, entries):
    directory = os.path.dirname(lock_path)
    fd, temporary = tempfile.mkstemp(prefix=".plugins.lock.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(entries, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, lock_path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def sync(repo):
    pb = os.path.join(repo, "personal-build")
    lock_path = os.path.join(pb, "plugins.lock.json")
    try:
        with open(lock_path, encoding="utf-8") as handle:
            entries = json.load(handle)
    except OSError as exc:
        raise SyncError("cannot read %s: %s" % (lock_path, exc))
    except ValueError as exc:
        raise SyncError("%s is not valid JSON: %s" % (lock_path, exc))
    if not isinstance(entries, list):
        raise SyncError("%s must contain a JSON array" % lock_path)

    token = find_token()
    if not token:
        log("No plugin release token configured; private plugins are skipped")

    updated = []
    skipped = []
    staged = []

    with tempfile.TemporaryDirectory(prefix="plugin-sync-", dir=pb) as workdir:
        for entry in entries:
            if not isinstance(entry, dict):
                raise SyncError("lock entries must be JSON objects")
            name = entry.get("name")
            spec = PLUGINS.get(name)
            if spec is None:
                log("%r is not one of the standalone plugins; skipped" % (name,))
                skipped.append(name)
                continue
            try:
                values, archive, asset_name = sync_entry(entry, spec, token, workdir)
            except SkipPlugin as exc:
                log("%s: skipped: %s" % (name, exc))
                skipped.append(name)
                continue
            if values is None:
                continue
            staged.append((entry, values, archive, asset_name))
            updated.append(name)

        if staged:
            for _entry, _values, archive, asset_name in staged:
                if archive:
                    store_archive(pb, asset_name, archive)
            for entry, values, _archive, _asset_name in staged:
                apply_values(entry, values)
            write_lock(lock_path, entries)
    return updated, skipped


def main(argv):
    if len(argv) != 2:
        log("usage: %s REPO" % os.path.basename(argv[0]))
        return 2
    repo = os.path.abspath(argv[1])
    try:
        updated, skipped = sync(repo)
    except SyncError as exc:
        log("ERROR: %s" % exc)
        return 1
    print(json.dumps({"updated": updated, "skipped": skipped}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
