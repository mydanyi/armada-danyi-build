#!/usr/bin/env python3
"""Seed image plugins without discarding updates or edits made by the user."""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

SKIP_DIRS = {"__pycache__"}
SKIP_SUFFIXES = (".pyc", ".pyo")
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]{0,63}$")


def file_digest(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect(root, relative, entries):
    with os.scandir(os.path.join(root, relative) if relative else root) as scan:
        items = sorted(scan, key=lambda item: item.name)
    for item in items:
        rel = item.name if not relative else relative + "/" + item.name
        if item.is_symlink():
            entries.append((rel, "link", os.readlink(item.path)))
        elif item.is_dir(follow_symlinks=False):
            if item.name not in SKIP_DIRS:
                collect(root, rel, entries)
        elif item.is_file(follow_symlinks=False):
            if item.name.endswith(SKIP_SUFFIXES):
                continue
            mode = item.stat(follow_symlinks=False).st_mode
            executable = "+x" if mode & 0o111 else "-x"
            entries.append((rel, "file", file_digest(item.path) + executable))


def tree_digest(root):
    entries = []
    collect(root, "", entries)
    digest = hashlib.sha256()
    for rel, kind, value in sorted(entries):
        digest.update(("%s\0%s\0%s\0" % (kind, rel, value)).encode("utf-8", "surrogateescape"))
    return digest.hexdigest()


def plugin_version(path):
    for name in ("package.json", "plugin.json"):
        try:
            with open(os.path.join(path, name), "rb") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            version = data.get("version")
            if isinstance(version, str) and VERSION_RE.fullmatch(version):
                return version
    return None


def compare_versions(left, right):
    if left == right:
        return 0
    # Same prerelease ordering as the loader: sort -V with '-' mapped to '~'.
    left_sort = left.replace("-", "~")
    right_sort = right.replace("-", "~")
    if left_sort == right_sort:
        return 0
    result = subprocess.run(
        ["sort", "-V"],
        input=left_sort + "\n" + right_sort + "\n",
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
        check=True,
    )
    lines = result.stdout.splitlines()
    if lines[1] == left_sort and lines[0] == right_sort:
        return 1
    if lines[1] == right_sort and lines[0] == left_sort:
        return -1
    return 0


def load_state(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}


def save_state(path, state):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    handle, tmp = tempfile.mkstemp(prefix=".armada-plugin-seed-", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(state, out, indent=2, sort_keys=True)
            out.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def replace_plugin(source, target):
    parent = os.path.dirname(target)
    staging = tempfile.mkdtemp(prefix=".armada-seed-", dir=parent)
    staged = os.path.join(staging, "plugin")
    try:
        shutil.copytree(source, staged, symlinks=True)
        if os.path.isdir(target) and not os.path.islink(target):
            shutil.rmtree(target)
        elif os.path.lexists(target):
            os.unlink(target)
        os.replace(staged, target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def sync_plugin(name, source, target, state):
    mirror_digest = tree_digest(source)
    if not os.path.lexists(target):
        replace_plugin(source, target)
    elif os.path.islink(target):
        # A link out of the plugins tree belongs to the user.
        return
    else:
        installed_digest = tree_digest(target)
        if installed_digest != mirror_digest:
            installed = plugin_version(target)
            mirror = plugin_version(source)
            recorded = state.get(name)
            if installed and mirror and compare_versions(installed, mirror) > 0:
                return
            if recorded and recorded == installed_digest:
                replace_plugin(source, target)
            elif recorded is None and installed and mirror and compare_versions(mirror, installed) > 0:
                replace_plugin(source, target)
            else:
                return
    if state.get(name) != mirror_digest:
        state[name] = mirror_digest


def main(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: armada-plugin-seed.py <image-dir> <plugins-dir> <state-json>\n")
        return 2
    source, plugins_dir, state_path = argv[1:4]
    if not os.path.isdir(source):
        return 0
    state = load_state(state_path)
    before = dict(state)
    for name in sorted(os.listdir(source)):
        plugin_src = os.path.join(source, name)
        if not os.path.isdir(plugin_src):
            continue
        sync_plugin(name, plugin_src, os.path.join(plugins_dir, name), state)
    if state != before:
        save_state(state_path, state)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
