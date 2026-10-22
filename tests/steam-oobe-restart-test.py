#!/usr/bin/env python3
"""Regressions for exit-42 relaunch supervision and --steam-oobe-only dispatch.

Expected to FAIL on baseline.  A fake native Steam runs in an isolated
HOME/STEAM_ROOT; no real Steam, /etc, or root path is touched.
Run: steam-oobe-restart-test.py [--repo REPO_ROOT] [unittest.args...]
"""

import argparse
import importlib.machinery
import importlib.util
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
LAUNCHER_REL = pathlib.Path("system_files/usr/libexec/armada/launch-steam")
FIXUPS_REL = pathlib.Path("system_files/usr/libexec/armada/armada-fixups")

TIMEOUT = 5
FIXUP_ORDER = (
    "fix_desktop_ownership",
    "fix_proton_11_tool_id",
    "strip_compat_wildcard",
    "migrate_sddm_autologin",
    "sync_steam_oobe",
)

# Counts invocations, records each invocation's argv, exits with the next
# scripted code.  wait-mode publishes its PID and exits 42 on SIGTERM, so a
# launcher that ignored termination would visibly relaunch it.
FAKE_STEAM = """#!/usr/bin/bash
set -u
count=$(cat "$HOME/calls.count" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s' "$count" > "$HOME/calls.count"
printf '%s\\n' "$@" > "$HOME/args.$count"
[[ -e "$HOME/write-completion" ]] && : > "$HOME/completed"
if [[ -e "$HOME/wait-mode" ]]; then
    printf '%s\\n' "$$" > "$HOME/child.pid"
    trap 'exit 42' TERM
    while :; do sleep 0.1; done
fi
exit "$(sed -n "${count}p" "$HOME/codes")"
"""


def repo_path(relative):
    return REPO / relative


def load_fixups():
    """Load the extensionless fixup script without running main()."""
    name = "armada_fixups_cli_under_test"
    path = str(repo_path(FIXUPS_REL))
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_file_location(name, path, loader=loader)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Fixture:
    """Isolated HOME/STEAM_ROOT plus an executable fake native Steam."""

    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.home = self.root / "home"
        self.steam_root = self.home / ".local/share/Steam"
        self.launcher = repo_path(LAUNCHER_REL)

    def prepare(self, codes, wait=False, completion=False):
        self.home.mkdir(parents=True, exist_ok=True)
        arm_dir = self.steam_root / "steamrtarm64"
        arm_dir.mkdir(parents=True, exist_ok=True)
        fake = arm_dir / "steam"
        fake.write_text(FAKE_STEAM, encoding="utf-8")
        fake.chmod(0o755)
        (self.home / "codes").write_text(
            "".join(f"{code}\n" for code in codes), encoding="utf-8"
        )
        if wait:
            (self.home / "wait-mode").touch()
        if completion:
            (self.home / "write-completion").touch()
        return self

    @property
    def env(self):
        return {
            "HOME": str(self.home), "STEAM_ROOT": str(self.steam_root),
            "TMPDIR": str(self.root), "PATH": "/usr/bin:/bin",
            "LANG": "C", "LC_ALL": "C",
        }

    def call_count(self):
        path = self.home / "calls.count"
        return int(path.read_text()) if path.exists() else 0

    def call_args(self, index):
        return (self.home / f"args.{index}").read_text().splitlines()


class LauncherTests(unittest.TestCase):
    def fixture(self, codes, wait=False, completion=False):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return Fixture(tmp.name).prepare(codes, wait=wait, completion=completion)

    def start(self, fixture, *args):
        proc = subprocess.Popen(
            ["/usr/bin/bash", str(fixture.launcher), *args], cwd=str(fixture.home),
            env=fixture.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True,
        )
        self.addCleanup(self.stop_group, proc)
        return proc

    @staticmethod
    def stop_group(proc):
        """Kill only the session/process group this harness started for proc.

        Signal the group even when the launcher itself already exited: a
        surviving child can still hold the inherited stdout/stderr pipes.
        """
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            proc.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            try:
                proc.communicate(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                pass

    def finish(self, proc):
        try:
            out, err = proc.communicate(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            self.stop_group(proc)
            try:
                out, err = proc.communicate(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                out, err = "", ""
                self.fail(
                    f"launcher exceeded {TIMEOUT}s and its process group did not exit"
                )
            self.fail(f"launcher exceeded {TIMEOUT}s: stdout={out!r} stderr={err!r}")
        return proc.returncode, out, err

    def run_launcher(self, fixture, *args):
        return self.finish(self.start(fixture, *args))

    def test_exit42_relaunches_once_with_identical_argv(self):
        fx = self.fixture([42, 0], completion=True)
        rc, _, err = self.run_launcher(fx, "-applaunch", "570", "-silent")

        self.assertEqual(rc, 0, f"exit 42 must be absorbed: {err}")
        self.assertEqual(fx.call_count(), 2, "relaunch must stay in one invocation")
        self.assertEqual(fx.call_args(1), ["-applaunch", "570", "-silent"])
        self.assertEqual(fx.call_args(2), fx.call_args(1))
        self.assertTrue((fx.home / "completed").exists())

    def test_repeated_exit42_restarts_until_clean_exit(self):
        fx = self.fixture([42, 42, 0])
        rc, _, err = self.run_launcher(fx, "-silent")

        self.assertEqual(rc, 0, err)
        self.assertEqual(fx.call_count(), 3)
        self.assertEqual(fx.call_args(3), fx.call_args(1))

    def test_other_failure_is_not_retried(self):
        fx = self.fixture([17])
        rc, _, _ = self.run_launcher(fx, "-silent")

        self.assertEqual(rc, 17, "non-42 failures must propagate unchanged")
        self.assertEqual(fx.call_count(), 1)

    def test_clean_exit_is_not_retried(self):
        fx = self.fixture([0])
        rc, _, _ = self.run_launcher(fx, "-silent")

        self.assertEqual(rc, 0)
        self.assertEqual(fx.call_count(), 1)

    def test_desktop_mode_forwarding_unchanged(self):
        fx = self.fixture([0])
        rc, _, err = self.run_launcher(fx, "--desktop", "-applaunch", "570")

        self.assertEqual(rc, 0, err)
        self.assertEqual(fx.call_args(1), ["-steamdeck", "-applaunch", "570"])

    def test_sigterm_stops_supervision_without_relaunch(self):
        fx = self.fixture([42, 0], wait=True)
        proc = self.start(fx)
        child = None
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            state = fx.home / "child.pid"
            if state.exists() and state.read_text().strip():
                child = int(state.read_text().strip())
                break
            time.sleep(0.05)
        self.assertIsNotNone(child, "fake Steam never published its PID")
        proc.send_signal(signal.SIGTERM)
        self.finish(proc)

        deadline = time.time() + 2
        while time.time() < deadline:
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            self.fail(f"Steam child {child} survived SIGTERM")

        self.assertEqual(fx.call_count(), 1, "no relaunch after SIGTERM")


class FixupDispatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_fixups()

    def dispatch(self, argv):
        order = []
        mocks = {
            name: mock.Mock(side_effect=lambda n=name, *a, **k: order.append(n))
            for name in FIXUP_ORDER
        }
        with mock.patch.multiple(self.module, **mocks), mock.patch.object(
            sys, "argv", argv
        ):
            self.module.main()
        return order

    def test_default_invocation_runs_full_fixup_sequence(self):
        self.assertEqual(self.dispatch(["armada-fixups"]), list(FIXUP_ORDER))

    def test_steam_oobe_only_runs_sync_only(self):
        self.assertEqual(
            self.dispatch(["armada-fixups", "--steam-oobe-only"]), ["sync_steam_oobe"])

    def test_unknown_argument_is_rejected(self):
        with self.assertRaises(SystemExit) as caught:
            self.dispatch(["armada-fixups", "--not-a-real-mode"])
        self.assertNotIn(caught.exception.code, (0, None))


def main():
    global REPO
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=str(REPO), help="repo checkout root")
    args, rest = parser.parse_known_args()
    REPO = pathlib.Path(args.repo).resolve()
    if not repo_path(LAUNCHER_REL).is_file():
        parser.error(f"missing launcher: {repo_path(LAUNCHER_REL)}")
    if not repo_path(FIXUPS_REL).is_file():
        parser.error(f"missing fixups: {repo_path(FIXUPS_REL)}")
    unittest.main(argv=[sys.argv[0], *rest])


if __name__ == "__main__":
    main()
