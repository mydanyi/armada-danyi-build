#!/usr/bin/env python3
"""Behavioural tests for the internal "单翼版" (danyi) update channel.

They drive the real production scripts:
  * system_files/usr/libexec/armada/armada-select-branch (-l / -c / selection)
  * system_files/usr/libexec/armada/armada-update (Steam's OS-update protocol)
  * system_files/usr/bin/steamos-update (Steam's OS-update entry)

The harness redirects the scripts' production absolute paths into a temporary
directory and fakes only the external command boundary (rpm-ostree, and the
personal updater). It never rewrites the channel decision logic itself: the
danyi<->单翼版 mapping, the personal-marker default and the official fallbacks
all run as shipped.

The official channel state (/var/lib/armada/update-channel) and the personal
(single-wing) channel state (/var/lib/armada/personal-update-channel) are kept
as two independent files: a personal image ignores a legacy official state and
only an explicit stable/beta/testing in the personal state switches it back.

Expected RED until update-lib / armada-select-branch split the two state paths.

No root, no network, no bootc: every fixture lives under the caller's TMPDIR.
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UPDATE_LIB = ROOT / "system_files/usr/lib/armada/update-lib"
SELECTOR = ROOT / "system_files/usr/libexec/armada/armada-select-branch"
ARMADA_UPDATE = ROOT / "system_files/usr/libexec/armada/armada-update"

CHANNEL_STATE = "/var/lib/armada/update-channel"
PERSONAL_CHANNEL_STATE = "/var/lib/armada/personal-update-channel"
PERSONAL_MARKER = "/usr/share/armada/personal-build/plugins.lock.json"

SINGLE_WING = "单翼版"


class ChannelSelectorTests(unittest.TestCase):
    """armada-select-branch: --list / --current and channel selection."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)

        self.bin = self.base / "bin"
        self.bin.mkdir()
        # rpm-ostree is the only external boundary the -c query touches; the
        # booted ref carries an official tag so the no-marker default is known.
        rpm = self.bin / "rpm-ostree"
        rpm.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' "
            "'{\"deployments\":[{\"container-image-reference\":"
            "\"ostree-unverified-registry:ghcr.io/armada-os/armada:stable\"}]}'\n"
        )
        rpm.chmod(0o755)

        # Path redirection only: point the shared library's writable state and
        # personal marker at fixtures instead of the production absolute paths.
        # The official channel state and the personal (single-wing) channel
        # state are two independent files; self.channel_state is the personal
        # one, self.official_channel the legacy/official one.
        self.channel_state = self.base / "update-channel"
        self.official_channel = self.base / "official-channel"
        self.marker = self.base / "plugins.lock.json"
        library = self.base / "update-lib"
        library.write_text(
            UPDATE_LIB.read_text()
            .replace(f'ARMADA_CHANNEL_STATE="{CHANNEL_STATE}"',
                     f'ARMADA_CHANNEL_STATE="{self.official_channel}"')
            .replace(f'ARMADA_PERSONAL_CHANNEL_STATE="{PERSONAL_CHANNEL_STATE}"',
                     f'ARMADA_PERSONAL_CHANNEL_STATE="{self.channel_state}"')
            .replace(PERSONAL_MARKER, str(self.marker))
        )
        self.selector = self.base / "armada-select-branch"
        self.selector.write_text(
            SELECTOR.read_text().replace(
                "source /usr/lib/armada/update-lib", f"source {library}")
        )
        self.selector.chmod(0o755)

        self.env = {**os.environ,
                    "PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}

    def set_marker(self, present):
        if present:
            self.marker.parent.mkdir(parents=True, exist_ok=True)
            self.marker.write_text("{}\n")
        else:
            self.marker.unlink(missing_ok=True)

    def set_official_state(self, channel=None):
        if channel is None:
            self.official_channel.unlink(missing_ok=True)
        else:
            self.official_channel.write_text(f"{channel}\n")

    def set_personal_state(self, channel=None):
        if channel is None:
            self.channel_state.unlink(missing_ok=True)
        else:
            self.channel_state.write_text(f"{channel}\n")

    def select(self, *arguments):
        return subprocess.run([str(self.selector), *arguments], env=self.env,
                              text=True, capture_output=True, timeout=10)

    def listed_tokens(self):
        result = self.select("-l")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.split()

    def current_token(self):
        result = self.select("-c")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_channel_list_offers_single_wing_and_official(self):
        self.set_marker(True)
        tokens = self.listed_tokens()
        self.assertIn(SINGLE_WING, tokens)
        for token in ("rel", "beta", "preview"):
            self.assertIn(token, tokens)

    def test_personal_marker_defaults_current_channel_to_single_wing(self):
        self.set_marker(True)
        self.assertEqual(self.current_token(), SINGLE_WING)

    def test_official_default_current_channel_without_marker(self):
        self.set_marker(False)
        token = self.current_token()
        self.assertNotEqual(token, SINGLE_WING)
        self.assertIn(token, ("rel", "beta", "preview"))

    def test_selection_accepts_internal_and_display_names(self):
        self.set_marker(True)
        for argument, stored in (("danyi", "danyi"), (SINGLE_WING, "danyi"),
                                 ("rel", "stable"), ("beta", "beta"),
                                 ("preview", "testing")):
            with self.subTest(argument=argument):
                result = self.select(argument)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.channel_state.read_text().strip(), stored)

    def test_selection_round_trips_through_current_channel(self):
        self.set_marker(True)
        self.select(SINGLE_WING)
        self.assertEqual(self.current_token(), SINGLE_WING)
        # An explicit official choice overrides the personal default.
        self.select("rel")
        self.assertEqual(self.current_token(), "rel")

    def test_explicit_official_selection_wins_over_personal_default(self):
        self.set_marker(True)
        # The personal image default-selects 单翼版; naming an official token
        # must record and report the official channel instead.
        for argument, expected in (("beta", "beta"), ("preview", "preview")):
            with self.subTest(argument=argument):
                self.select(argument)
                self.assertEqual(self.current_token(), expected)

    def test_legacy_official_state_does_not_override_personal_default(self):
        self.set_marker(True)
        # A personal image must ignore a stale official channel state: with no
        # personal selection the default stays 单翼版 for every legacy value.
        for legacy in ("stable", "beta", "testing"):
            with self.subTest(legacy=legacy):
                self.set_personal_state(None)
                self.set_official_state(legacy)
                self.assertEqual(self.current_token(), SINGLE_WING)

    def test_official_selection_records_personal_and_official_state(self):
        self.set_marker(True)
        # Choosing an official channel must persist the personal choice and also
        # refresh the official state so both agree after crossing to ghcr.
        for argument, stored in (("rel", "stable"), ("beta", "beta"),
                                 ("preview", "testing")):
            with self.subTest(argument=argument):
                self.select(argument)
                self.assertEqual(self.channel_state.read_text().strip(), stored)
                self.assertEqual(self.official_channel.read_text().strip(), stored)

    def test_danyi_selection_only_writes_the_personal_state(self):
        self.set_marker(True)
        self.set_official_state("beta")
        self.select("danyi")
        self.assertEqual(self.channel_state.read_text().strip(), "danyi")
        # The personal choice never rewrites the official channel state.
        self.assertEqual(self.official_channel.read_text().strip(), "beta")

    def test_unknown_channel_token_is_rejected(self):
        self.set_marker(True)
        result = self.select("bogus")
        self.assertNotEqual(result.returncode, 0)


class PersonalSteamDispatchTests(unittest.TestCase):
    """armada-update must hand a personal build to the personal updater.

    The real armada-update and the real update-lib are copied verbatim; only
    their absolute marker / state / helper paths are redirected. rpm-ostree and
    the personal updater are the sole faked external boundaries, so this proves
    armada-update's own entry dispatch (Steam's --check / --steam protocol and
    its no-official-network guarantee) rather than re-faking the whole script.
    """

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)

        self.bin = self.base / "bin"
        self.bin.mkdir()

        # rpm-ostree: the booted ref names an official channel; with the personal
        # marker present the routing must still pick the personal target.
        rpm = self.bin / "rpm-ostree"
        rpm.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' "
            "'{\"deployments\":[{\"container-image-reference\":"
            "\"ostree-unverified-registry:ghcr.io/armada-os/armada:stable\"}]}'\n"
        )
        rpm.chmod(0o755)

        self.marker = self.base / "plugins.lock.json"
        self.marker.write_text("{}\n")
        self.official_channel = self.base / "official-update-channel"
        self.personal_channel = self.base / "personal-update-channel"

        # The personal updater is the external boundary: it records its argv and
        # emits a configurable version / progress line and exit status.
        self.helper_log = self.base / "helper.log"
        helper = self.base / "armada-danyi-update"
        helper.write_text(
            "#!/usr/bin/env bash\n"
            f'printf \'%s\\n\' "$*" >> "{self.helper_log}"\n'
            'if [[ -n "${PERSONAL_HELPER_OUT:-}" ]]; then '
            'printf \'%s\\n\' "$PERSONAL_HELPER_OUT"; fi\n'
            'exit "${PERSONAL_HELPER_RC:-0}"\n'
        )
        helper.chmod(0o755)
        self.helper = helper

        # The official tools must never run on the personal path; recording
        # stubs make any accidental call visible.
        self.forbidden_log = self.base / "forbidden.log"
        for name in ("skopeo", "bootc"):
            stub = self.bin / name
            stub.write_text(
                "#!/usr/bin/env bash\n"
                f'printf \'%s %s\\n\' "{name}" "$*" >> "{self.forbidden_log}"\n'
                "exit 0\n"
            )
            stub.chmod(0o755)

        library = self.base / "update-lib"
        library.write_text(
            UPDATE_LIB.read_text()
            .replace(f'ARMADA_CHANNEL_STATE="{CHANNEL_STATE}"',
                     f'ARMADA_CHANNEL_STATE="{self.official_channel}"')
            .replace(f'ARMADA_PERSONAL_CHANNEL_STATE="{PERSONAL_CHANNEL_STATE}"',
                     f'ARMADA_PERSONAL_CHANNEL_STATE="{self.personal_channel}"')
            .replace(PERSONAL_MARKER, str(self.marker))
        )

        update = self.base / "armada-update"
        update.write_text(
            ARMADA_UPDATE.read_text()
            .replace("source /usr/lib/armada/update-lib", f"source {library}")
            .replace("/usr/bin/armada-danyi-update", str(self.helper))
        )
        update.chmod(0o755)
        self.update = update

        self.env = {**os.environ,
                    "PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}

    def dispatch(self, *arguments, helper_out=None, helper_rc=None):
        env = dict(self.env)
        if helper_out is not None:
            env["PERSONAL_HELPER_OUT"] = helper_out
        if helper_rc is not None:
            env["PERSONAL_HELPER_RC"] = str(helper_rc)
        return subprocess.run([str(self.update), *arguments], env=env,
                              text=True, capture_output=True, timeout=10)

    def helper_calls(self):
        if not self.helper_log.exists():
            return []
        return self.helper_log.read_text().splitlines()

    def forbidden_calls(self):
        if not self.forbidden_log.exists():
            return []
        return self.forbidden_log.read_text().splitlines()

    def test_capability_probe_succeeds_without_the_personal_helper(self):
        self.helper.unlink()
        result = self.dispatch("--supports-duplicate-detection")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_personal_check_dispatches_check_to_the_personal_helper(self):
        result = self.dispatch("check", helper_out="20261015.new")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.helper_calls(), ["--check"])
        self.assertEqual(result.stdout.strip(), "20261015.new")
        self.assertEqual(self.forbidden_calls(), [])

    def test_personal_apply_dispatches_steam_to_the_personal_helper(self):
        result = self.dispatch(helper_out="42%")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.helper_calls(), ["--steam"])
        self.assertEqual(result.stdout.strip(), "42%")
        self.assertEqual(self.forbidden_calls(), [])

    def test_personal_helper_error7_stays_personal_and_off_the_network(self):
        result = self.dispatch("check", helper_rc=7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(self.helper_calls(), ["--check"])
        self.assertEqual(self.forbidden_calls(), [])


if __name__ == "__main__":
    unittest.main()
