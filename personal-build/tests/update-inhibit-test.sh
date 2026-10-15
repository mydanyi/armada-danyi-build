#!/usr/bin/env bash
# Behavioral regression test for the power-inhibit lock in personal-build/update.sh.
#
# Contract under test (Codex design, not yet implemented -> today this is RED):
#
#   update.sh must acquire a real systemd-inhibit wrapper lock
#       systemd-inhibit --what=idle:sleep --mode=block <command...>
#   BEFORE its first network request / download / merge / bootc switch, and must
#   keep that lock held for the whole update flow (download SHA256SUMS and every
#   volume -> verify -> merge -> `bootc switch`), releasing it only when the flow
#   ends.  Read-only prechecks (root / `uname -m` == aarch64 / `bootc status`)
#   may run OUTSIDE the lock.  The implementation wraps its former main body in a
#   Bash function and runs it from a child bash under systemd-inhibit, so there is
#   no forgeable "skip the lock" environment flag and no recursive re-entry.
#   It never changes user power settings, never installs a background service and
#   never reboots.
#
# This test drives the SAME observable boundary a real systemd-inhibit would sit
# on: a mock `systemd-inhibit` on PATH parses --what/--mode, records an acquire
# event, creates a lock-holder marker, THEN runs the wrapped command as a child,
# and removes the marker on exit (including on SIGTERM).  The mock `curl` and
# `bootc` used by the update flow assert the lock-holder marker exists while they
# run, so a lock that does not cover the flow is caught.  The mock is a stand-in
# for the systemd-inhibit CLI, NOT a verification of the real D-Bus inhibit
# interface; the test is behavioural, not a static grep of update.sh.
#
# Scenarios (one per required assertion):
#   1. explicit tag  -> lock lifecycle + ordering: acquire first, lock held
#      across curl/bootc switch, released last, release-tag preserved.
#   2. no tag        -> the FIRST network request (GitHub API) is inside the lock.
#   3. lock failure  -> no curl, no bootc switch, no cache data written.
#   4. download fail -> non-zero exit, lock released, no leftover mock processes.
#   5. interrupt     -> independent process group, TERM while the lock is held,
#      group exits, lock released, no leftover mock tasks.
#
# Everything runs inside the root test container; all fixtures live in the
# caller's $TMPDIR and are owned by mktemp/trap.  No network, no real bootc, no
# reboot, no real D-Bus.  All CPU work runs remotely under Codex -- do not run
# this locally.
set -euo pipefail
export LC_ALL=C

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UPDATE="$TESTS_DIR/../update.sh"
UPD_ROOT="/var/lib/armada-danyi-updates"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
sha()  { sha256sum -- "$1" | cut -d' ' -f1; }
mk_blob() { head -c "$2" /dev/zero | tr '\0' "${3:-A}" > "$1"; }

# First line number (1-based) of the first line matching an ERE, or empty.
line_of() { grep -nE -- "$1" "$2" 2>/dev/null | head -n1 | cut -d: -f1 || true; }

printf '==> update-inhibit regression test\n'

# ---- RED guard: the target must exist before behaviour is exercised ---------
[[ -f "$UPDATE" ]] || { printf 'RED: target script missing: %s\n' "$UPDATE" >&2; exit 1; }

# update.sh refuses to run unless root; the whole test drives it, so require root.
[[ "${EUID}" -eq 0 ]] \
    || fail "this test drives update.sh and must run as root inside the remote Docker host"

: "${TMPDIR:=/tmp}"
[[ "$TMPDIR" == /* && "$TMPDIR" != "/" && -w "$TMPDIR" ]] \
    || fail "TMPDIR must be an absolute writable directory: $TMPDIR"

WORK="$(mktemp -d "$TMPDIR/update-inhibit.XXXXXX")"
TAG="armada-test-20261015"
RELEASE_TAG="$TAG"
VERSION="20261015.abcd1234"
OCI_NAME="armada-$VERSION.oci.tar"
IMG_NAME="armada-$VERSION.img.gz"

FAKEBIN="$WORK/bin"
FAKECURL="$WORK/curl-src"
EVENTS="$WORK/events.log"
HOLDER="$WORK/lock.holder"
CURL_ENTERED="$WORK/curl.entered"
VIOLATIONS="$WORK/violations.log"
mkdir -p "$FAKEBIN" "$FAKECURL"

# Best-effort mock-process census: prints PIDs still running a fake tool.
mock_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f -- "$FAKEBIN" 2>/dev/null | grep -vx -- "$$" || true
    else
        local p line
        for p in /proc/[0-9]*; do
            [[ -r "$p/cmdline" ]] || continue
            line="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"
            case "$line" in *"$FAKEBIN"*) printf '%s\n' "${p#/proc/}" ;; esac
        done
    fi
}
assert_no_mock_leftovers() {
    local label="$1" pids
    pids="$(mock_pids)"
    [[ -z "$pids" ]] || fail "$label: leftover mock processes remain: $pids"
}

cleanup() {
    # Reap anything the interrupt scenario may have left behind, then fixtures.
    local pids
    pids="$(mock_pids)"
    [[ -n "$pids" ]] && kill -KILL $pids 2>/dev/null || true
    rm -rf -- "$WORK"
    rm -rf -- "$UPD_ROOT/$TAG"
    rmdir -- "$UPD_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Fixtures: fake tools on PATH
# ============================================================================

# --- mock systemd-inhibit: parse --what/--mode, hold marker, run the command --
cat > "$FAKEBIN/systemd-inhibit" <<'INHIBIT'
#!/usr/bin/env bash
# Neutralise any errtrace/nounset inherited through SHELLOPTS from update.sh.
set +e +u
ev="${FAKE_EVENT_LOG:?}"
what=""; mode=""; cmd=()
args=("$@"); i=0; n=${#args[@]}
while (( i < n )); do
    a="${args[$i]}"
    case "$a" in
        --what=*) what="${a#--what=}" ;;
        --what)   ((i+=1)); what="${args[$i]:-}" ;;
        --mode=*) mode="${a#--mode=}" ;;
        --mode)   ((i+=1)); mode="${args[$i]:-}" ;;
        --who=*|--why=*) : ;;
        --who|--why) ((i+=1)) ;;
        --list|--version|--help|-h) : ;;
        --) ((i+=1)); cmd=("${args[@]:i}"); break ;;
        -*) : ;;
        *) cmd=("${args[@]:i}"); break ;;
    esac
    ((i+=1))
done

printf 'inhibit-invoked what=%s mode=%s\n' "$what" "$mode" >> "$ev"

bad=0
case ":${what:-}:" in *:idle:*)  : ;; *) bad=1 ;; esac
case ":${what:-}:" in *:sleep:*) : ;; *) bad=1 ;; esac
[[ "${mode:-}" == "block" ]] || bad=1
if (( bad )); then
    printf 'inhibit-bad-args what=%s mode=%s\n' "$what" "$mode" >> "$ev"
    printf 'mock-systemd-inhibit: --what must contain idle and sleep and --mode must be block (got what=%s mode=%s)\n' "$what" "$mode" >&2
    exit 2
fi

if [[ -n "${FAKE_INHIBIT_FAIL:-}" ]]; then
    printf 'inhibit-acquire-failed\n' >> "$ev"
    printf 'mock-systemd-inhibit: could not acquire idle:sleep block lock\n' >&2
    exit 1
fi

holder="${FAKE_INHIBIT_HOLDER:?}"
: > "$holder"
printf 'inhibit-acquire what=%s mode=%s pid=%s\n' "$what" "$mode" "$$" >> "$ev"

release() { rm -f -- "$holder"; printf 'inhibit-release rc=%s\n' "${1:-0}" >> "$ev"; }

if (( ${#cmd[@]} == 0 )); then
    printf 'inhibit-no-command\n' >> "$ev"; release 0; exit 0
fi

child=""; term=0
on_signal() { term=1; [[ -n "$child" ]] && kill -s TERM "$child" 2>/dev/null || true; }
trap on_signal TERM INT

# The command only runs AFTER the lock marker exists; lock is released on exit.
"${cmd[@]}" &
child=$!
wait "$child"; rc=$?
if (( term )); then release 143; exit 143; fi
release "$rc"
exit "$rc"
INHIBIT
chmod +x "$FAKEBIN/systemd-inhibit"

# --- mock curl: serve fixtures by basename; record ordering + lock coverage ---
cat > "$FAKEBIN/curl" <<'CURL'
#!/usr/bin/env bash
set +e +u
ev="${FAKE_EVENT_LOG:?}"
out=""; url=""
args=("$@"); i=0; n=${#args[@]}
while (( i < n )); do
    a="${args[$i]}"
    case "$a" in
        -o|--output) ((i+=1)); out="${args[$i]:-}" ;;
        --output=*)  out="${a#--output=}" ;;
        --*) : ;;
        -*) rest="${a#-}"
            if [[ "$rest" == *o ]]; then ((i+=1)); out="${args[$i]:-}"
            elif [[ "$rest" == *o* ]]; then out="${rest#*o}"; fi ;;
        *) url="$a" ;;
    esac
    ((i+=1))
done

printf 'curl %s\n' "$url" >> "$ev"
if [[ ! -e "${FAKE_INHIBIT_HOLDER:?}" ]]; then
    printf 'curl-outside-lock %s\n' "$url" >> "${FAKE_VIOLATION_LOG:?}"
fi

if [[ "$url" == "https://api.github.com/repos/mydanyi/armada-danyi-build/releases/latest" ]]; then
    body="{\"tag_name\":\"${FAKE_RELEASE_TAG:?}\"}"
    if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
    exit 0
fi

# Interrupt scenario: block on the first asset request while the lock is held.
if [[ -n "${FAKE_CURL_HANG:-}" ]]; then
    : > "${FAKE_CURL_ENTERED:?}"
    printf 'curl-hang %s\n' "$url" >> "$ev"
    sleep 600
    exit 0
fi

name="${url%%\?*}"; name="${name##*/}"
src="${FAKE_CURL_DIR:?}/$name"
[[ -f "$src" ]] || { printf 'curl-failed %s\n' "$url" >> "$ev"; printf 'fake-curl: 404 for %s\n' "$url" >&2; exit 22; }
if [[ -n "$out" ]]; then cp -f -- "$src" "$out"; else cat -- "$src"; fi
exit 0
CURL
chmod +x "$FAKEBIN/curl"

# --- mock bootc: status/switch; switch must observe the lock holder -----------
cat > "$FAKEBIN/bootc" <<'BOOTC'
#!/usr/bin/env bash
set +e +u
printf 'bootc %s\n' "$*" >> "${FAKE_EVENT_LOG:?}"
case "${1:-}" in
    status) exit "${FAKE_BOOTC_STATUS_RC:-0}" ;;
    switch)
        if [[ ! -e "${FAKE_INHIBIT_HOLDER:?}" ]]; then
            printf 'bootc-switch-outside-lock %s\n' "$*" >> "${FAKE_VIOLATION_LOG:?}"
        fi
        exit "${FAKE_BOOTC_SWITCH_RC:-0}" ;;
    *) exit 0 ;;
esac
BOOTC
chmod +x "$FAKEBIN/bootc"

# --- mock uname: aarch64 for -m; otherwise defer to the real tool -------------
cat > "$FAKEBIN/uname" <<'UNAME'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then printf '%s\n' "${FAKE_UNAME_M:-aarch64}"; exit 0; fi
if [[ -x /usr/bin/uname ]]; then exec /usr/bin/uname "$@"; fi
exec /bin/uname "$@"
UNAME
chmod +x "$FAKEBIN/uname"

# --- forbid reboot: record any invocation (must stay empty) -------------------
for c in reboot systemctl; do
    cat > "$FAKEBIN/$c" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$c" "\$*" >> "\${FAKE_FORBIDDEN_LOG:?}"
exit 0
EOF
    chmod +x "$FAKEBIN/$c"
done

# ============================================================================
# Helpers: fixtures + drivers
# ============================================================================

prepare_oci_release() {  # tiny valid release: SHA256SUMS + OCI volumes
    rm -rf -- "$FAKECURL"; mkdir -p "$FAKECURL"
    mk_blob "$WORK/oci.full" 48 A
    FULL_SHA="$(sha "$WORK/oci.full")"
    split -b 16 -d -a 3 -- "$WORK/oci.full" "$FAKECURL/$OCI_NAME.part"
    mk_blob "$WORK/img.full" 32 B
    IMG_SHA="$(sha "$WORK/img.full")"
    {
        printf '%s  %s\n' "$IMG_SHA"  "$IMG_NAME"
        printf '%s  %s\n' "$FULL_SHA" "$OCI_NAME"
        local p
        for p in "$FAKECURL/$OCI_NAME.part"*; do
            printf '%s  %s\n' "$(sha "$p")" "$(basename "$p")"
        done
    } > "$FAKECURL/SHA256SUMS"
}

reset_run_state() {
    : > "$EVENTS"; : > "$VIOLATIONS"; : > "$WORK/forbidden.log"
    rm -f -- "$HOLDER" "$CURL_ENTERED"
    rm -rf -- "$UPD_ROOT/$TAG"
}

run_update() {  # run_update <label> [release-tag ...]
    local label="$1"; shift || true
    reset_run_state
    set +e
    env \
        PATH="$FAKEBIN:/usr/bin:/bin" \
        FAKE_EVENT_LOG="$EVENTS" \
        FAKE_VIOLATION_LOG="$VIOLATIONS" \
        FAKE_INHIBIT_HOLDER="$HOLDER" \
        FAKE_INHIBIT_FAIL="${FAKE_INHIBIT_FAIL:-}" \
        FAKE_CURL_DIR="$FAKECURL" \
        FAKE_RELEASE_TAG="$RELEASE_TAG" \
        FAKE_FORBIDDEN_LOG="$WORK/forbidden.log" \
        FAKE_UNAME_M=aarch64 \
        bash "$UPDATE" "$@" >"$WORK/$label.out" 2>&1
    update_rc=$?
    set -e
}

# ============================================================================
# Scenario 1 + 4 -- success with an explicit tag: lock lifecycle, ordering,
#                   tag preservation
# ============================================================================
prepare_oci_release
FAKE_INHIBIT_FAIL= run_update success "$TAG"

[[ "$update_rc" -eq 0 ]] || fail "update.sh failed on a valid release: $(cat "$WORK/success.out")"

grep -qE '^inhibit-invoked ' "$EVENTS" \
    || fail "RED: update.sh never invoked systemd-inhibit around the update flow (missing power lock)"

acq_line="$(line_of '^inhibit-acquire ' "$EVENTS")"
[[ -n "$acq_line" ]] \
    || fail "RED: systemd-inhibit never acquired an idle:sleep block lock (no inhibit-acquire event)"
acq="$(sed -n "${acq_line}p" "$EVENTS")"
case "$acq" in *idle*)       : ;; *) fail "the lock --what does not include idle: $acq" ;; esac
case "$acq" in *sleep*)      : ;; *) fail "the lock --what does not include sleep: $acq" ;; esac
case "$acq" in *"mode=block"*) : ;; *) fail "the lock --mode is not block: $acq" ;; esac

curl_line="$(line_of '^curl ' "$EVENTS")"
switch_line="$(line_of '^bootc switch' "$EVENTS")"
rel_line="$(grep -nE '^inhibit-release' "$EVENTS" 2>/dev/null | tail -n1 | cut -d: -f1 || true)"

[[ -n "$curl_line" ]]   || fail "update.sh made no network request"
[[ -n "$switch_line" ]] || fail "update.sh did not run bootc switch"
[[ -n "$rel_line" ]]    || fail "systemd-inhibit never released the lock"
(( acq_line < curl_line )) \
    || fail "the first network request ran before the lock was acquired (acquire@$acq_line curl@$curl_line)"
(( acq_line < switch_line )) \
    || fail "bootc switch ran before the lock was acquired (acquire@$acq_line switch@$switch_line)"
(( switch_line < rel_line )) \
    || fail "the lock was released before bootc switch (switch@$switch_line release@$rel_line)"

[[ ! -e "$HOLDER" ]] || fail "the lock marker still exists after update.sh exited"
[[ ! -s "$VIOLATIONS" ]] || fail "curl/bootc ran without the inhibit lock: $(cat "$VIOLATIONS")"

MERGED="$UPD_ROOT/$TAG/$OCI_NAME"
[[ -f "$MERGED" ]] || fail "update.sh did not stage the merged OCI at $MERGED"
[[ "$(sha "$MERGED")" == "$FULL_SHA" ]] || fail "the merged OCI does not match the published package"
[[ "$(grep -cE '^bootc switch' "$EVENTS" || true)" -eq 1 ]] || fail "expected exactly one bootc switch"
grep -q -- '--transport oci-archive' "$EVENTS" || fail "bootc switch did not use --transport oci-archive"
! grep -q -- '--apply' "$EVENTS" || fail "update.sh invoked bootc --apply"
grep -qF -- "/$TAG/" "$EVENTS" || fail "update.sh did not download under the passed release-tag"
grep -qF -- "$MERGED" "$EVENTS" || fail "bootc switch did not name the merged OCI under the passed tag"
! grep -qE '^(reboot|systemctl)( |$)' "$WORK/forbidden.log" || fail "update.sh called reboot/systemctl"
pass 'update.sh: systemd-inhibit lock wraps download+merge+switch; release-tag preserved'

# ============================================================================
# Scenario 2 -- no tag: the first network request (GitHub API) is inside the lock
# ============================================================================
prepare_oci_release
FAKE_INHIBIT_FAIL= run_update apipath

[[ "$update_rc" -eq 0 ]] || fail "update.sh failed on the API tag path: $(cat "$WORK/apipath.out")"
api_line="$(line_of '^curl https://api\.github\.com' "$EVENTS")"
acq2_line="$(line_of '^inhibit-acquire ' "$EVENTS")"
[[ -n "$api_line" ]] || fail "update.sh did not query the GitHub releases/latest API"
[[ -n "$acq2_line" ]] || fail "RED: no inhibit lock on the API tag path"
(( acq2_line < api_line )) \
    || fail "the first network request (GitHub API) ran before the lock was acquired (acquire@$acq2_line api@$api_line)"
[[ ! -e "$HOLDER" ]] || fail "the lock was not released on the API path"
[[ ! -s "$VIOLATIONS" ]] || fail "curl/bootc ran outside the lock on the API path: $(cat "$VIOLATIONS")"
pass 'update.sh: the first network request (GitHub API) is inside the lock'

# ============================================================================
# Scenario 3 -- lock acquisition fails: nothing is downloaded or switched
# ============================================================================
prepare_oci_release
FAKE_INHIBIT_FAIL=1 run_update lockfail "$TAG"

[[ "$update_rc" -ne 0 ]] || fail "update.sh exited 0 even though the inhibit lock could not be acquired"
grep -qE '^inhibit-invoked ' "$EVENTS" \
    || fail "RED: update.sh never asked systemd-inhibit for the lock"
grep -qE '^inhibit-acquire-failed' "$EVENTS" || fail "the mock lock was not actually asked to lock"
! grep -qE '^inhibit-acquire ' "$EVENTS" || fail "lock reported acquired despite the acquisition failure"
! grep -qE '^curl ' "$EVENTS" || fail "update.sh made network requests without the lock"
! grep -qE '^bootc switch' "$EVENTS" || fail "update.sh ran bootc switch without the lock"
if [[ -d "$UPD_ROOT/$TAG" ]]; then
    leftovers="$(find "$UPD_ROOT/$TAG" -type f -printf '%P\n' 2>/dev/null || true)"
    [[ -z "$leftovers" ]] || fail "cache data changed without the lock: $leftovers"
fi
[[ ! -e "$HOLDER" ]] || fail "the lock marker was left behind after a failed acquisition"
# bootc status (a read-only precheck) is explicitly allowed outside the lock.
pass 'update.sh: a failed lock acquisition aborts before any download or switch'

# ============================================================================
# Scenario 4 -- a downstream curl failure: non-zero exit, lock released, no leaks
# ============================================================================
prepare_oci_release
rm -f -- "$FAKECURL/$OCI_NAME.part001"
FAKE_INHIBIT_FAIL= run_update curl_404 "$TAG"

[[ "$update_rc" -ne 0 ]] || fail "update.sh exited 0 though a volume download failed"
! grep -qE '^bootc switch' "$EVENTS" || fail "bootc switch ran despite the failed download"
grep -qE '^inhibit-release' "$EVENTS" || fail "the lock was not released after the failed download"
[[ ! -e "$HOLDER" ]] || fail "the lock marker was left behind after the failed download"
assert_no_mock_leftovers "download-failure"
pass 'update.sh: a failed download exits non-zero and releases the lock'

# ============================================================================
# Scenario 5 -- interrupt: TERM the process group while the lock is held
# ============================================================================
if ! command -v setsid >/dev/null 2>&1; then
    printf 'SKIP: setsid unavailable, cannot create an independent process group\n'
else
    prepare_oci_release
    reset_run_state

    setsid env \
        PATH="$FAKEBIN:/usr/bin:/bin" \
        FAKE_EVENT_LOG="$EVENTS" \
        FAKE_VIOLATION_LOG="$VIOLATIONS" \
        FAKE_INHIBIT_HOLDER="$HOLDER" \
        FAKE_CURL_DIR="$FAKECURL" \
        FAKE_RELEASE_TAG="$RELEASE_TAG" \
        FAKE_FORBIDDEN_LOG="$WORK/forbidden.log" \
        FAKE_UNAME_M=aarch64 \
        FAKE_CURL_HANG=1 FAKE_CURL_ENTERED="$CURL_ENTERED" \
        bash "$UPDATE" "$TAG" >"$WORK/interrupt.out" 2>&1 &
    pgid=$!

    # Wait until the lock is held AND the download is blocked in flight.
    for _ in $(seq 1 300); do
        [[ -e "$HOLDER" && -e "$CURL_ENTERED" ]] && break
        sleep 0.1
    done
    [[ -e "$HOLDER" ]] \
        || fail "RED: no inhibit lock was held while the download was in flight"
    [[ -e "$CURL_ENTERED" ]] \
        || fail "update.sh never reached the in-flight download under the lock"
    grep -qE '^inhibit-acquire ' "$EVENTS" || fail "RED: no lock acquired before the download"
    [[ ! -s "$VIOLATIONS" ]] || fail "curl/bootc ran outside the lock during the interrupt run"

    kill -TERM -- "-$pgid" 2>/dev/null || true
    gone=0
    for _ in $(seq 1 200); do
        if ! kill -0 -- "-$pgid" 2>/dev/null; then gone=1; break; fi
        sleep 0.1
    done
    if (( ! gone )); then
        kill -KILL -- "-$pgid" 2>/dev/null || true
        fail "the update process group survived SIGTERM"
    fi
    set +e; wait "$pgid" 2>/dev/null; set -e

    [[ ! -e "$HOLDER" ]] || fail "the lock was not released after the process group was TERM'd"
    grep -qE '^inhibit-release' "$EVENTS" || fail "the mock lock did not release on shutdown"
    ! grep -qE '^bootc switch' "$EVENTS" || fail "bootc switch ran after the interrupt"
    assert_no_mock_leftovers "interrupt"
    pass 'update.sh: SIGTERM to the process group aborts, releases the lock, no leftovers'
fi

printf '\nupdate-inhibit tests passed\n'
exit 0
