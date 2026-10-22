#!/usr/bin/env python3
"""Behavioral tests for the forthcoming Steam OOBE marker fix (upstream PR744).

The implementation under test is the extensionless fixup script; it is loaded
via importlib with a non-__main__ module name so its main() never runs. Every
test redirects HOME_DIR and STEAM_OOBE_IMAGE into a throwaway temp tree.
"""

import importlib.machinery
import importlib.util
import pathlib
import tempfile
import unittest
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXUPS_PATH = REPO_ROOT / "system_files/usr/libexec/armada/armada-fixups"

# (subtest label, registry path relative to HOME_DIR, registry body)
COMPLETED_REGISTRIES = (
    ("stage1_in_home_registry", ".steam/registry.vdf", '"CompletedOOBEStage1"\t\t"1"'),
    ("legacy_in_steam_registry", ".local/share/Steam/registry.vdf", '"CompletedOOBE"\t\t"1"'),
)
FALSE_REGISTRIES = (
    ("stage1_false_in_home_registry", ".steam/registry.vdf", '"CompletedOOBEStage1"\t\t"0"'),
    ("legacy_false_in_steam_registry", ".local/share/Steam/registry.vdf", '"CompletedOOBE"\t\t"0"'),
)

LOGINUSERS_VDF = (
    '"users"\n'
    "{\n"
    '\t"76561198000000000"\n'
    "\t{\n"
    '\t\t"AccountName"\t\t"armada"\n'
    "\t}\n"
    "}\n"
)

MAIN_FIXUPS = (
    "fix_desktop_ownership",
    "fix_proton_11_tool_id",
    "strip_compat_wildcard",
    "migrate_sddm_autologin",
    "sync_steam_oobe",
)


def load_fixups():
    """Load the extensionless script without executing main()."""
    name = "armada_fixups_under_test"
    loader = importlib.machinery.SourceFileLoader(name, str(FIXUPS_PATH))
    spec = importlib.util.spec_from_file_location(name, str(FIXUPS_PATH), loader=loader)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Sandbox:
    """Isolated HOME plus fake /etc marker location for one scenario."""

    def __init__(self, root):
        self.root = root
        self.home = root / "home"
        self.steam = self.home / ".local/share/Steam"
        self.marker = root / "etc/steamos-oobe-image"

    def prepare(self):
        self.home.mkdir(parents=True, exist_ok=True)
        self.marker.parent.mkdir(parents=True, exist_ok=True)
        return self

    def seed_steam(self):
        self.steam.mkdir(parents=True, exist_ok=True)
        return self

    def create_marker(self):
        self.marker.touch()
        return self

    def write(self, relative_path, text):
        path = self.home / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path


class SteamOOBETests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_fixups()

    def sandbox(self):
        class _Ctx:
            def __enter__(ctx):
                ctx._tmp = tempfile.TemporaryDirectory()
                env = Sandbox(pathlib.Path(ctx._tmp.name)).prepare()
                ctx._patches = [
                    mock.patch.object(self.module, "HOME_DIR", env.home),
                    mock.patch.object(self.module, "STEAM_OOBE_IMAGE", env.marker),
                ]
                for patch in ctx._patches:
                    patch.start()
                return env

            def __exit__(ctx, *exc_info):
                for patch in reversed(ctx._patches):
                    patch.stop()
                ctx._tmp.cleanup()
                return False

        return _Ctx()

    def test_contract_exposes_sync_function_and_image_constant(self):
        fresh = load_fixups()
        self.assertTrue(
            hasattr(fresh, "STEAM_OOBE_IMAGE"),
            "baseline fixups lacks STEAM_OOBE_IMAGE",
        )
        self.assertIsInstance(fresh.STEAM_OOBE_IMAGE, pathlib.Path)
        self.assertTrue(
            callable(getattr(fresh, "sync_steam_oobe", None)),
            "baseline fixups lacks sync_steam_oobe()",
        )

    def test_no_steam_seed_directory_does_not_create_marker(self):
        with self.sandbox() as env:
            self.module.sync_steam_oobe()

            self.assertFalse(env.steam.exists())
            self.assertFalse(env.marker.exists())

    def test_fresh_seed_without_records_creates_marker(self):
        with self.sandbox() as env:
            env.seed_steam()

            self.module.sync_steam_oobe()

            self.assertTrue(env.marker.is_file())

    def test_completed_registry_records_remove_marker(self):
        for label, registry_path, body in COMPLETED_REGISTRIES:
            with self.subTest(record=label), self.sandbox() as env:
                env.seed_steam().create_marker()
                env.write(registry_path, body + "\n")

                self.module.sync_steam_oobe()

                self.assertFalse(env.marker.exists())

    def test_false_completion_still_creates_marker(self):
        for label, registry_path, body in FALSE_REGISTRIES:
            with self.subTest(record=label), self.sandbox() as env:
                env.seed_steam()
                env.write(registry_path, body + "\n")

                self.module.sync_steam_oobe()

                self.assertTrue(env.marker.is_file())

    def test_loginusers_account_removes_marker_and_preserves_bytes(self):
        with self.sandbox() as env:
            env.seed_steam().create_marker()
            loginusers = env.write(".local/share/Steam/config/loginusers.vdf", LOGINUSERS_VDF)
            before = loginusers.read_bytes()

            self.module.sync_steam_oobe()

            self.assertFalse(env.marker.exists())
            self.assertEqual(loginusers.read_bytes(), before)

    def test_completed_then_repeat_run_keeps_marker_removed(self):
        with self.sandbox() as env:
            env.seed_steam()

            self.module.sync_steam_oobe()
            self.assertTrue(env.marker.is_file(), "fresh seed should show the OOBE image")

            env.write(".steam/registry.vdf", '"CompletedOOBEStage1"\t\t"1"\n')
            self.module.sync_steam_oobe()
            self.assertFalse(env.marker.exists(), "completion should remove the OOBE image")

            self.module.sync_steam_oobe()
            self.assertFalse(env.marker.exists(), "second completed run must stay idempotent")

    def test_main_invokes_sync_steam_oobe_with_existing_fixups(self):
        with mock.patch.multiple(self.module, **{name: mock.DEFAULT for name in MAIN_FIXUPS}) as mocks:
            self.module.main([])

            for name in MAIN_FIXUPS:
                self.assertEqual(
                    mocks[name].call_count,
                    1,
                    f"main() should call {name}() exactly once",
                )


if __name__ == "__main__":
    unittest.main()
