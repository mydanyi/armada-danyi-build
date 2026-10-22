#!/usr/bin/bash
# Activation test for armada-steam-oobe.path inside a disposable container.
#
# It exercises the INSTALLED units and the production HOME path
# /var/home/armada, simulating Steam's registry writes.  It never reboots,
# starts SDDM or Steam, touches disks/ABL, uses the network, or installs
# packages.  Run only from a manager-created container:
#
#   ARMADA_OOBE_DISPOSABLE_TEST=1 tests/steam-oobe-path-test.sh
set -euo pipefail

PATH_UNIT=armada-steam-oobe.path
SERVICE_UNIT=armada-steam-oobe.service
FIXUPS=/usr/libexec/armada/armada-fixups
HOME_DIR=/var/home/armada
MARKER=/etc/steamos-oobe-image
REG_HOME=${HOME_DIR}/.steam/registry.vdf
REG_STEAM=${HOME_DIR}/.local/share/Steam/registry.vdf
LOGINUSERS=${HOME_DIR}/.local/share/Steam/config/loginusers.vdf
TIMEOUT=5
BURST_WRITES=8

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
phase() { printf 'phase: %s\n' "$*"; }

cleanup() {
    local status=$?
    systemctl stop "$PATH_UNIT" >/dev/null 2>&1 || true
    if (( status == 0 )); then
        rm -f "$MARKER" "$REG_HOME" "$REG_STEAM" "$LOGINUSERS"
    else
        printf 'note: leaving failure evidence under %s and %s\n' "$HOME_DIR" "$MARKER" >&2
    fi
}

# --- preconditions -----------------------------------------------------------
[[ ${ARMADA_OOBE_DISPOSABLE_TEST:-0} == 1 ]] ||
    fail "refusing: set ARMADA_OOBE_DISPOSABLE_TEST=1 (disposable container only)"
(( EUID == 0 )) || fail "refusing: must run as root inside the disposable container"
[[ "$(cat /proc/1/comm 2>/dev/null)" == systemd ]] ||
    fail "refusing: PID 1 is not systemd"
systemctl show --property=Version --value >/dev/null 2>&1 ||
    fail "refusing: systemctl cannot reach PID 1"
[[ -x $FIXUPS ]] ||
    fail "missing installed fixup source $FIXUPS (manager must install the repo copy)"
systemctl cat "$PATH_UNIT" >/dev/null 2>&1 ||
    fail "missing unit $PATH_UNIT (expected before implementation)"
systemctl cat "$SERVICE_UNIT" >/dev/null 2>&1 ||
    fail "missing unit $SERVICE_UNIT (expected before implementation)"

# Registered only once every guard above passed: a refusal stays read-only.
trap cleanup EXIT

install -d -m 0755 "${HOME_DIR}/.steam" "${HOME_DIR}/.local/share/Steam/config"

# --- helpers -----------------------------------------------------------------
marker_state() { [[ -e $MARKER ]] && printf present || printf absent; }

service_state() { systemctl show --property=ActiveState --value "$SERVICE_UNIT" 2>/dev/null || true; }

invocation_id() { systemctl show --property=InvocationID --value "$SERVICE_UNIT" 2>/dev/null || true; }

evidence() {
    printf '  marker=%s path=%s service=%s result=%s\n' \
        "$(marker_state)" \
        "$(systemctl show --property=ActiveState --value "$PATH_UNIT" 2>/dev/null || true)" \
        "$(service_state)" \
        "$(systemctl show --property=Result --value "$SERVICE_UNIT" 2>/dev/null || true)"
}

service_snapshot() {
    systemctl show --property=ActiveState,SubState,Result,InvocationID,NRestarts \
        "$SERVICE_UNIT" 2>&1 || true
    systemctl show --property=ActiveState,SubState,Result "$PATH_UNIT" 2>&1 || true
}

wait_idle() {
    local deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
        case $(service_state) in
            activating | reloading) sleep 0.1 ;;
            *) return 0 ;;
        esac
    done
    return 1
}

wait_marker_absent() {
    local deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
        [[ ! -e $MARKER ]] && return 0
        sleep 0.1
    done
    return 1
}

wait_run() { # $1: invocation id captured before the write
    local deadline=$((SECONDS + TIMEOUT)) now
    while (( SECONDS < deadline )); do
        now=$(invocation_id)
        if [[ -n $now && $now != "$1" ]]; then
            wait_idle && return 0
        fi
        sleep 0.1
    done
    return 1
}

begin_case() {
    systemctl stop "$PATH_UNIT" >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
    rm -f "$REG_HOME" "$REG_STEAM" "$LOGINUSERS"
    touch "$MARKER"
    systemctl start "$PATH_UNIT" || fail "$1: cannot start $PATH_UNIT"
    systemctl is-active --quiet "$PATH_UNIT" ||
        fail "$1: $PATH_UNIT did not become active"
    phase "$1: watcher active, marker present"
}

# --- cases -------------------------------------------------------------------
case_atomic_registry_replace() {
    local tmp
    begin_case "atomic replace of .steam/registry.vdf with CompletedOOBEStage1=1"
    tmp=$(mktemp "${REG_HOME}.XXXXXX")
    printf '"InstallConfigStore"\n{\n\t"CompletedOOBEStage1"\t\t"1"\n}\n' > "$tmp"
    mv -f "$tmp" "$REG_HOME"
    wait_marker_absent || {
        evidence
        fail "marker not removed within ${TIMEOUT}s after atomic replacement"
    }
    wait_idle || { evidence; fail "oneshot did not settle after atomic replacement"; }
    evidence
    phase "ok: marker removed by atomic replace"
}

case_inplace_other_registry() {
    begin_case "in-place write of .local/share/Steam/registry.vdf with CompletedOOBE=1"
    printf '"InstallConfigStore"\n{\n\t"CompletedOOBE"\t\t"1"\n}\n' > "$REG_STEAM"
    wait_marker_absent || {
        evidence
        fail "marker not removed within ${TIMEOUT}s after in-place registry write"
    }
    wait_idle || { evidence; fail "oneshot did not settle after in-place write"; }
    evidence
    phase "ok: marker removed by in-place write"
}

case_loginusers_account() {
    begin_case "loginusers.vdf gaining an AccountName"
    printf '"users"\n{\n\t"76561198000000000"\n\t{\n\t\t"AccountName"\t\t"armada"\n\t}\n}\n' \
        > "$LOGINUSERS"
    wait_marker_absent || {
        evidence
        fail "marker not removed within ${TIMEOUT}s after AccountName write"
    }
    wait_idle || { evidence; fail "oneshot did not settle after loginusers write"; }
    evidence
    phase "ok: marker removed by loginusers write"
}

case_incomplete_registry() {
    local before
    begin_case "CompletedOOBEStage1=0 must retain the marker"
    before=$(invocation_id)
    printf '"InstallConfigStore"\n{\n\t"CompletedOOBEStage1"\t\t"0"\n}\n' > "$REG_HOME"
    wait_run "$before" || {
        evidence
        fail "path did not activate the oneshot for an incomplete registry"
    }
    [[ "$(systemctl show --property=Result --value "$SERVICE_UNIT")" == success ]] || {
        evidence
        fail "oneshot failed instead of retaining the marker"
    }
    [[ -e $MARKER ]] || { evidence; fail "marker removed for CompletedOOBEStage1=0"; }
    evidence
    phase "ok: marker retained for incomplete registry"
}

case_cleared_marker_not_recreated() {
    begin_case "a cleared marker must not be recreated by later completed writes"
    printf '"InstallConfigStore"\n{\n\t"CompletedOOBE"\t\t"1"\n}\n' > "$REG_STEAM"
    wait_marker_absent || {
        evidence
        fail "marker not removed within ${TIMEOUT}s before the recreate check"
    }
    printf '"InstallConfigStore"\n{\n\t"CompletedOOBEStage1"\t\t"1"\n}\n' > "$REG_HOME"
    sleep 1
    wait_idle || true
    [[ ! -e $MARKER ]] || { evidence; fail "later write recreated the marker"; }
    evidence
    phase "ok: cleared marker stayed absent"
}

case_repeated_incomplete_writes() {
    local before elapsed i started
    begin_case "burst of ${BURST_WRITES} closed incomplete writes must not exhaust the oneshot start limit"
    started=$SECONDS
    for (( i = 1; i <= BURST_WRITES; i += 1 )); do
        before=$(invocation_id)
        printf '"InstallConfigStore"\n{\n\t"CompletedOOBEStage1"\t\t"0"\n}\n' > "$REG_HOME"
        wait_run "$before" || {
            evidence
            service_snapshot
            fail "write ${i}/${BURST_WRITES}: path did not start the oneshot (start limit or refusal)"
        }
        systemctl is-active --quiet "$PATH_UNIT" || {
            evidence
            service_snapshot
            fail "write ${i}/${BURST_WRITES}: $PATH_UNIT stopped watching"
        }
        [[ "$(systemctl show --property=Result --value "$SERVICE_UNIT")" == success ]] || {
            evidence
            service_snapshot
            fail "write ${i}/${BURST_WRITES}: incomplete oneshot did not succeed"
        }
        [[ -e $MARKER ]] || {
            evidence
            fail "write ${i}/${BURST_WRITES}: marker removed for CompletedOOBEStage1=0"
        }
    done
    elapsed=$((SECONDS - started))
    # QEMU/systemctl overhead inflates the total; report it without treating
    # the whole 8-write duration as a correctness condition.
    phase "burst: ${BURST_WRITES} separate invocations in ${elapsed}s"
    printf '"InstallConfigStore"\n{\n\t"CompletedOOBEStage1"\t\t"1"\n}\n' > "$REG_HOME"
    wait_marker_absent || {
        evidence
        service_snapshot
        fail "marker not removed within ${TIMEOUT}s for the completion write after the burst"
    }
    wait_idle || { evidence; fail "oneshot did not settle after the completion write"; }
    systemctl is-active --quiet "$PATH_UNIT" ||
        { evidence; service_snapshot; fail "$PATH_UNIT is not active after the burst"; }
    [[ "$(systemctl show --property=Result --value "$SERVICE_UNIT")" == success ]] || {
        evidence
        service_snapshot
        fail "completion oneshot after the burst did not succeed"
    }
    evidence
    phase "ok: ${BURST_WRITES} rapid incomplete writes left the watcher armed; completion cleared the marker"
}

phase "preflight passed: units installed, fixup source present"
case_atomic_registry_replace
case_inplace_other_registry
case_loginusers_account
case_incomplete_registry
case_cleared_marker_not_recreated
case_repeated_incomplete_writes
printf 'ALL CASES PASSED\n'
