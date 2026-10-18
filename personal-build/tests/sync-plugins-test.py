#!/usr/bin/env python3
"""Behavioural tests for the personal-build plugin sync helper.

Contract under test (T003)::

    python3 personal-build/sync-plugins.py REPO

reads ``REPO/personal-build/plugins.lock.json`` and refreshes the three
standalone plugins it lists -- armada-installer, "LSFG-VK ARM64" and
DeckyClash -- from release metadata served by GitHub's API. These tests drive
the real CLI as a subprocess against a loopback HTTP fixture: no network, no
real credentials, no builds and no third-party packages.

stdout is exactly one JSON object -- ``{"updated": [...], "skipped": [...]}`` --
on success; logs go to stderr and failures exit non-zero. Lock entries and
private ZIPs may only change after *every* entry validated, so any failure must
leave locks and packages byte-identical.

Run with TEST_TMP_ROOT pointing at an absolute writable task directory.
"""

import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from collections import namedtuple
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SYNCER = TESTS_DIR.parent / "sync-plugins.py"

# Repositories each lock URL points at; the fixture serves the same paths.
INSTALLER_REPO = ("mydanyi", "armada-installer")
LSFG_REPO = ("mydanyi", "decky-lsfg-vk-arm64")
CLASH_REPO = ("chenx-dust", "DeckyClash")

FAKE_TOKEN = "fixture-token-not-real-4c1f"

TMP_ROOT = None

# Inherited credentials and proxies must never reach the helper under test: the
# only token is the clearly fake fixture one written per test.
_DROPPED_ENV = {
    "GH_TOKEN", "GITHUB_TOKEN",
    "ARMADA_PLUGIN_TOKEN_FILE", "ARMADA_PLUGIN_API_BASE",
    "ARMADA_EXECUTION_BASE",
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
    "http_proxy", "https_proxy", "all_proxy",
}
SAFE_ENV = {key: value for key, value in os.environ.items() if key not in _DROPPED_ENV}
SAFE_ENV["NO_PROXY"] = SAFE_ENV["no_proxy"] = "127.0.0.1,localhost"

Request = namedtuple("Request", "path authorization accept")


def _validated_tmp_root():
    root = os.environ.get("TEST_TMP_ROOT", "")
    if not root:
        raise AssertionError("TEST_TMP_ROOT must be set to the task writable directory")
    path = Path(root)
    if not path.is_absolute() or str(path) == "/" or not path.is_dir() or not os.access(root, os.W_OK):
        raise AssertionError("TEST_TMP_ROOT must be an absolute writable task dir: %s" % root)
    return path


def setUpModule():  # noqa: N802 -- unittest protocol
    global TMP_ROOT
    TMP_ROOT = _validated_tmp_root()
    if not SYNCER.is_file():
        raise AssertionError(
            "sync-plugins.py is not implemented yet: expected %s "
            "(the T003 entry point). Behavioural tests are not run against a "
            "missing CLI." % SYNCER
        )


def plugin_zip(directory, include=("plugin.json", "main.py", "dist/index.js"), marker=""):
    """A real, small plugin ZIP laid out as <directory>/<relative file>."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for relative in include:
            if relative == "plugin.json":
                body = json.dumps({"name": directory, "version": "fixture" + marker})
            elif relative == "main.py":
                body = "print(%r)\n" % ("fixture" + marker)
            else:
                body = "export default %r;\n" % ("fixture" + marker)
            archive.writestr("%s/%s" % (directory, relative), body)
    return buffer.getvalue()


def installer_entry(version="0.1.0", sha256="0" * 64):
    tag = "v" + version
    return {
        "name": "armada-installer",
        "version": version,
        "url": "https://github.com/%s/%s/releases/download/%s/armada-installer-%s.zip"
        % (INSTALLER_REPO + (tag, version)),
        "sha256": sha256,
        "directory": "armada-installer",
    }


def clash_entry(version="1.3.5", sha256="0" * 64):
    return {
        "name": "DeckyClash",
        "version": version,
        "url": "https://github.com/%s/%s/releases/download/v%s/DeckyClash-full-linux-arm64.zip"
        % (CLASH_REPO + (version,)),
        "sha256": sha256,
        "directory": "DeckyClash",
    }


class LoopbackApi:
    """GitHub-like release API and asset host on 127.0.0.1 only."""

    def __init__(self):
        self.routes = {}
        self.requests = []
        self._asset_id = 0
        self._guard = threading.Lock()
        api = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                authorization = self.headers.get("Authorization", "")
                accept = self.headers.get("Accept", "")
                with api._guard:
                    api.requests.append(Request(self.path, authorization, accept))
                route = api.routes.get(self.path)
                if route is None or (route["token"] and not api._authorized(authorization)):
                    self._reply(404, b'{"message":"Not Found"}')
                    return
                required = route.get("accept")
                if required and accept != required:
                    self._reply(404, b'{"message":"Not Found"}')
                    return
                self._reply(200, route["body"])

            def _reply(self, status, body):
                self.send_response(status)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=self.httpd.serve_forever, name="plugin-api", daemon=True
        )
        self.thread.start()
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]

    @staticmethod
    def _authorized(header):
        return header in {"Bearer " + FAKE_TOKEN, "token " + FAKE_TOKEN}

    def release(self, owner, repo, tag, assets, draft=False, prerelease=False, token=False):
        listed = []
        for asset in assets:
            name = asset["name"]
            data = asset["data"]
            self._asset_id += 1
            path = "/downloads/%s/%s/%s" % (owner, repo, name)
            api_path = "/repos/%s/%s/releases/assets/%d" % (owner, repo, self._asset_id)
            # A private asset is only reachable with a credential, both through
            # the Release Asset API and through its browser download URL.
            self.routes[path] = {"body": data, "token": token}
            self.routes[api_path] = {
                "body": data,
                "token": token,
                "accept": "application/octet-stream",
            }
            entry = {
                "name": name,
                "browser_download_url": self.base + path,
                "url": self.base + api_path,
            }
            digest = asset.get("digest")
            if digest is None:
                digest = "sha256:" + hashlib.sha256(data).hexdigest()
            if digest is not False:
                entry["digest"] = digest
            listed.append(entry)
        payload = {
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "assets": listed,
        }
        self.routes["/repos/%s/%s/releases/latest" % (owner, repo)] = {
            "body": json.dumps(payload).encode("utf-8"),
            "token": token,
        }

    def downloads(self):
        return [
            request.path
            for request in self.requests
            if request.path.startswith("/downloads/") or "/releases/assets/" in request.path
        ]

    def asset_requests(self):
        return [request for request in self.requests if "/releases/assets/" in request.path]

    def api_auth(self):
        return [
            request.authorization
            for request in self.requests
            if request.path.startswith("/repos/")
        ]

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


class SyncPluginsCase(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="sync-plugins-", dir=str(TMP_ROOT)))
        self.addCleanup(shutil.rmtree, str(self.work), True)
        self.repo = self.work / "repo"
        (self.repo / "personal-build").mkdir(parents=True)
        self.lock_path = self.repo / "personal-build" / "plugins.lock.json"
        self.api = LoopbackApi()
        self.addCleanup(self.api.close)
        self.env = dict(SAFE_ENV)
        self.env["ARMADA_PLUGIN_API_BASE"] = self.api.base

    # -- fixture helpers ---------------------------------------------------
    def write_lock(self, entries):
        self.lock_path.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
        return self.lock_path.read_bytes()

    def lock(self):
        return json.loads(self.lock_path.read_text(encoding="utf-8"))

    def entry(self, name):
        return next(item for item in self.lock() if item["name"] == name)

    def use_token(self):
        token_file = self.work / "plugin-token"
        token_file.write_text(FAKE_TOKEN + "\n", encoding="utf-8")
        os.chmod(str(token_file), 0o600)
        self.env["ARMADA_PLUGIN_TOKEN_FILE"] = str(token_file)

    def add_private_lsfg(self, version="0.14.4-preview.1"):
        data = plugin_zip("LSFG-VK ARM64", marker="-" + version)
        asset = "LSFG-VK-ARM64-%s-full.zip" % version
        archive = self.repo / "personal-build" / "plugin-assets" / asset
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(data)
        entry = {
            "name": "LSFG-VK ARM64",
            "version": version,
            "url": "https://github.com/%s/%s/releases/download/v%s/%s"
            % (LSFG_REPO + (version, asset)),
            "sha256": hashlib.sha256(data).hexdigest(),
            "archive": "personal-build/plugin-assets/" + asset,
            "directory": "LSFG-VK ARM64",
        }
        return entry, archive, data

    # -- process boundary --------------------------------------------------
    def _run(self):
        return subprocess.run(
            [sys.executable, str(SYNCER), str(self.repo)],
            cwd=str(self.work),
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
        )

    def run_ok(self):
        proc = self._run()
        self.assertEqual(
            proc.returncode,
            0,
            "sync-plugins failed (rc=%d)\nstdout:\n%s\nstderr:\n%s"
            % (proc.returncode, proc.stdout, proc.stderr),
        )
        return proc

    def run_fail(self):
        proc = self._run()
        self.assertNotEqual(
            proc.returncode,
            0,
            "sync-plugins must fail here\nstdout:\n%s\nstderr:\n%s"
            % (proc.stdout, proc.stderr),
        )
        return proc

    def output(self, proc):
        try:
            data = json.loads(proc.stdout)
        except ValueError as exc:
            self.fail("stdout is not exactly one JSON object (%s): %r" % (exc, proc.stdout))
        self.assertIsInstance(data, dict, "stdout JSON must be an object: %r" % (data,))
        for key in ("updated", "skipped"):
            self.assertIn(key, data)
            self.assertIsInstance(data[key], list)
        return data


class PublicInstallerTests(SyncPluginsCase):
    def test_public_installer_upgrade(self):
        package = plugin_zip("armada-installer", marker="-0.2.0")
        self.api.release(
            *INSTALLER_REPO, "v0.2.0",
            [{"name": "armada-installer-0.2.0.zip", "data": package}],
        )
        self.write_lock([installer_entry()])

        output = self.output(self.run_ok())

        self.assertEqual(output["updated"], ["armada-installer"])
        entry = self.entry("armada-installer")
        self.assertEqual(entry["version"], "0.2.0")
        self.assertEqual(entry["sha256"], hashlib.sha256(package).hexdigest())
        self.assertEqual(
            entry["url"],
            self.api.base + "/downloads/mydanyi/armada-installer/armada-installer-0.2.0.zip",
        )
        self.assertEqual(entry["directory"], "armada-installer")
        self.assertNotIn("archive", entry)
        self.assertEqual(len(self.api.downloads()), 1)

    def test_same_version_and_digest_is_a_noop(self):
        package = plugin_zip("armada-installer", marker="-0.2.0")
        before = self.write_lock(
            [installer_entry("0.2.0", hashlib.sha256(package).hexdigest())]
        )
        self.api.release(
            *INSTALLER_REPO, "v0.2.0",
            [{"name": "armada-installer-0.2.0.zip", "data": package}],
        )

        output = self.output(self.run_ok())

        self.assertEqual(output["updated"], [])
        self.assertEqual(self.api.downloads(), [], "unchanged lock must not download the asset")
        self.assertEqual(self.lock_path.read_bytes(), before, "unchanged lock must not be rewritten")

    def test_older_latest_does_not_downgrade(self):
        package = plugin_zip("armada-installer", marker="-0.1.0")
        before = self.write_lock(
            [installer_entry("0.2.0", hashlib.sha256(package).hexdigest())]
        )
        self.api.release(
            *INSTALLER_REPO, "v0.1.0",
            [{"name": "armada-installer-0.1.0.zip", "data": package}],
        )

        output = self.output(self.run_ok())

        self.assertEqual(output["updated"], [])
        self.assertEqual(self.entry("armada-installer")["version"], "0.2.0")
        self.assertEqual(self.api.downloads(), [])
        self.assertEqual(self.lock_path.read_bytes(), before)

    def test_prerelease_release_is_not_used(self):
        package = plugin_zip("armada-installer", marker="-0.2.0")
        before = self.write_lock([installer_entry()])
        self.api.release(
            *INSTALLER_REPO, "v0.2.0",
            [{"name": "armada-installer-0.2.0.zip", "data": package}],
            prerelease=True,
        )

        output = self.output(self.run_ok())

        self.assertEqual(output["updated"], [])
        self.assertEqual(self.entry("armada-installer")["version"], "0.1.0")
        self.assertEqual(self.api.downloads(), [])
        self.assertEqual(self.lock_path.read_bytes(), before)

    def test_draft_release_is_not_used(self):
        package = plugin_zip("armada-installer", marker="-0.2.0")
        before = self.write_lock([installer_entry()])
        self.api.release(
            *INSTALLER_REPO, "v0.2.0",
            [{"name": "armada-installer-0.2.0.zip", "data": package}],
            draft=True,
        )

        output = self.output(self.run_ok())

        self.assertEqual(output["updated"], [])
        self.assertEqual(self.entry("armada-installer")["version"], "0.1.0")
        self.assertEqual(self.api.downloads(), [])
        self.assertEqual(self.lock_path.read_bytes(), before)


class PrivateLsfgTests(SyncPluginsCase):
    def test_private_lsfg_updates_with_token(self):
        entry, _old_archive, _old_data = self.add_private_lsfg()
        self.write_lock([entry])
        self.use_token()
        package = plugin_zip("LSFG-VK ARM64", marker="-preview.2")
        asset = "LSFG-VK-ARM64-0.14.4-preview.2-full.zip"
        self.api.release(
            *LSFG_REPO, "v0.14.4-preview.2",
            [{"name": asset, "data": package}],
            token=True,
        )

        proc = self.run_ok()
        output = self.output(proc)

        self.assertEqual(output["updated"], ["LSFG-VK ARM64"])
        updated = self.entry("LSFG-VK ARM64")
        self.assertEqual(updated["version"], "0.14.4-preview.2")
        self.assertEqual(updated["sha256"], hashlib.sha256(package).hexdigest())
        self.assertEqual(
            updated["archive"], "personal-build/plugin-assets/" + asset
        )
        stored = self.repo / updated["archive"]
        self.assertTrue(stored.is_file(), "new private package was not stored")
        self.assertEqual(stored.read_bytes(), package)
        # The private ZIP must come through the authenticated Release Asset API,
        # not through the browser download URL.
        self.assertEqual(
            self.api.downloads(),
            ["/repos/mydanyi/decky-lsfg-vk-arm64/releases/assets/1"],
        )
        asset_requests = self.api.asset_requests()
        self.assertEqual(len(asset_requests), 1, "private asset API was not used")
        self.assertIn(FAKE_TOKEN, asset_requests[0].authorization)
        self.assertEqual(asset_requests[0].accept, "application/octet-stream")
        # The metadata call authenticated, and the token never leaked out.
        self.assertTrue(self.api.api_auth())
        for header in self.api.api_auth():
            self.assertIn(FAKE_TOKEN, header)
        for surface in (proc.stdout, proc.stderr,
                        self.lock_path.read_text(encoding="utf-8")):
            self.assertNotIn(FAKE_TOKEN, surface)

    def test_private_lsfg_without_token_is_skipped(self):
        entry, old_archive, old_data = self.add_private_lsfg()
        self.write_lock([installer_entry(), entry])
        installer_package = plugin_zip("armada-installer", marker="-0.2.0")
        self.api.release(
            *INSTALLER_REPO, "v0.2.0",
            [{"name": "armada-installer-0.2.0.zip", "data": installer_package}],
        )
        self.api.release(
            *LSFG_REPO, "v0.14.4-preview.2",
            [{"name": "LSFG-VK-ARM64-0.14.4-preview.2-full.zip",
              "data": plugin_zip("LSFG-VK ARM64", marker="-preview.2")}],
            token=True,
        )

        output = self.output(self.run_ok())

        # A missing private credential skips only that plugin.
        self.assertEqual(set(output["updated"]), {"armada-installer"})
        self.assertIn("LSFG-VK ARM64", output["skipped"])
        self.assertEqual(self.entry("armada-installer")["version"], "0.2.0")
        self.assertEqual(self.entry("LSFG-VK ARM64"), entry)
        self.assertEqual(old_archive.read_bytes(), old_data)
        self.assertFalse(
            any("LSFG-VK-ARM64" in path for path in self.api.downloads()),
            "a skipped private plugin must not be downloaded",
        )
        # Whether the helper probes the private API or skips before the call,
        # no credential may be attached (there is none).
        lsfg_auth = [
            request.authorization
            for request in self.api.requests
            if "decky-lsfg-vk-arm64" in request.path
        ]
        self.assertTrue(all(header == "" for header in lsfg_auth))


class ValidationFailureTests(SyncPluginsCase):
    def test_digest_mismatch_leaves_everything_untouched(self):
        lsfg, old_archive, old_data = self.add_private_lsfg()
        before = self.write_lock([installer_entry(), lsfg, clash_entry()])
        self.use_token()

        self.api.release(
            *INSTALLER_REPO, "v0.2.0",
            [{"name": "armada-installer-0.2.0.zip",
              "data": plugin_zip("armada-installer", marker="-0.2.0")}],
        )
        self.api.release(
            *LSFG_REPO, "v0.14.4-preview.2",
            [{"name": "LSFG-VK-ARM64-0.14.4-preview.2-full.zip",
              "data": plugin_zip("LSFG-VK ARM64", marker="-preview.2")}],
            token=True,
        )
        self.api.release(
            *CLASH_REPO, "v1.3.6",
            [{"name": "DeckyClash-full-linux-arm64.zip",
              "data": plugin_zip("DeckyClash", marker="-1.3.6"),
              "digest": "sha256:" + "0" * 64}],
        )

        self.run_fail()

        # No half update: installer and LSFG were valid, clash was not.
        self.assertEqual(self.lock_path.read_bytes(), before)
        self.assertEqual(old_archive.read_bytes(), old_data)
        assets = sorted(path.name for path in old_archive.parent.iterdir())
        self.assertEqual(assets, [old_archive.name])

    def test_missing_plugin_file_fails_without_changes(self):
        # A ZIP lacking dist/index.js is not a valid plugin package.
        broken = plugin_zip(
            "armada-installer", include=("plugin.json", "main.py"), marker="-0.2.0"
        )
        before = self.write_lock([installer_entry()])
        self.api.release(
            *INSTALLER_REPO, "v0.2.0",
            [{"name": "armada-installer-0.2.0.zip", "data": broken}],
        )

        self.run_fail()

        self.assertEqual(self.lock_path.read_bytes(), before)


class DeckyClashTests(SyncPluginsCase):
    def test_clash_uses_arm64_full_asset_only(self):
        arm64 = plugin_zip("DeckyClash", marker="-arm64")
        amd64 = plugin_zip("DeckyClash", marker="-amd64")
        self.api.release(
            *CLASH_REPO, "v1.3.6",
            [
                {"name": "DeckyClash-full-linux-amd64.zip", "data": amd64},
                {"name": "DeckyClash-full-linux-arm64.zip", "data": arm64},
            ],
        )
        self.write_lock([clash_entry()])

        output = self.output(self.run_ok())

        self.assertEqual(output["updated"], ["DeckyClash"])
        self.assertEqual(
            self.api.downloads(),
            ["/downloads/chenx-dust/DeckyClash/DeckyClash-full-linux-arm64.zip"],
        )
        entry = self.entry("DeckyClash")
        self.assertEqual(entry["version"], "1.3.6")
        self.assertEqual(entry["sha256"], hashlib.sha256(arm64).hexdigest())
        self.assertTrue(entry["url"].endswith("/DeckyClash-full-linux-arm64.zip"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
