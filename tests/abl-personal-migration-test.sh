#!/usr/bin/env bash
# Personal ABL migration regressions for the danyi-default-zh build.
#
# Drives the real armada-abl-update against regular-file ABL partitions and a
# fake target root. Cases 1 and 2 cover the approved personal migrations and are
# expected to fail until the updater honours
# usr/lib/openabl-updater/personal-migrations.tsv. Every other case is expected
# to stay green on the upstream baseline.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/packages/openabl-updater"
UPDATE="$PKG/src/armada-abl-update"
VERSION_TOOL="$PKG/src/abl-version"
if [[ ! -f "$UPDATE" || ! -f "$VERSION_TOOL" ]]; then
    printf 'fixture error: updater sources not found under %s\n' "$PKG" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { printf 'fixture error: %s\n' "$*" >&2; exit 2; }
fail_msg() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; }

TARGET="$WORK/root"
PAYLOAD_DIR="$TARGET/usr/lib/openabl-updater"
PAYLOAD="$PAYLOAD_DIR/abl_signed-SM8550.elf"
MIGRATIONS="$PAYLOAD_DIR/personal-migrations.tsv"
CATALOG="$WORK/legacy-releases.tsv"
mkdir -p "$PAYLOAD_DIR" "$WORK/bin"

blob_size=8192
make_blob() {
    python3 - "$1" "$2" "${3:-$blob_size}" <<'PY'
import sys

path, tag, raw_size = sys.argv[1:]
size = int(raw_size)
pattern = tag.encode() + b"\0"
with open(path, "wb") as output:
    output.write((pattern * (size // len(pattern) + 1))[:size])
PY
}
hash_of() { sha256sum "$1" | cut -d' ' -f1; }

# The packaged personal payload plus the synthetic sources this build must
# recognize as migration inputs.
make_blob "$PAYLOAD" danyi-default-zh-1.1-sm8550
official_110="$WORK/official-1.1"
personal_100="$WORK/personal-1.0"
unknown_110="$WORK/unknown-1.1"
newer_120="$WORK/newer-1.2"
wrong_soc="$WORK/wrong-soc"
make_blob "$official_110" official-openabl-1.1-sm8550
make_blob "$personal_100" personal-openabl-1.0-sm8550
make_blob "$unknown_110" unknown-openabl-1.1-sm8550
make_blob "$newer_120" openabl-1.2-sm8550
make_blob "$wrong_soc" openabl-1.1-sm8650

target_hash=$(hash_of "$PAYLOAD")
target_size=$(stat -c %s "$PAYLOAD")
[[ "$target_size" == "$blob_size" ]] || die "target payload size drifted"

# Upstream catalog schema; the old personal 1.0 is deliberately absent.
{
    printf 'abl\tversion\tsoc\tsize\tsha256\n'
    printf 'OpenABL\t1.1\tSM8550\t%s\t%s\n' "$blob_size" "$(hash_of "$official_110")"
    printf 'OpenABL\t1.1\tSM8650\t%s\t%s\n' "$blob_size" "$(hash_of "$wrong_soc")"
    printf 'OpenABL\t1.2\tSM8550\t%s\t%s\n' "$blob_size" "$(hash_of "$newer_120")"
} > "$CATALOG"

cat > "$PAYLOAD_DIR/manifest" <<EOF
ARMADA_ABL_NAME=OpenABL
ARMADA_ABL_VERSION=1.1
ARMADA_ABL_VARIANT=danyi-default-zh
ARMADA_ABL_SHA256_SM8550=${target_hash}
EOF

identify() { ARMADA_ABL_RELEASES="$CATALOG" python3 "$VERSION_TOOL" "$@"; }
[[ "$(identify --with-soc "$official_110")" == "OpenABL 1.1 SM8550" ]] ||
    die "catalog does not identify the official 1.1 payload"
identify "$personal_100" >/dev/null 2>&1 &&
    die "old personal 1.0 must not be in the upstream catalog"

# Write the approved migration table from tab-separated rows.
write_migrations() {
    local row
    {
        printf 'version\tsoc\tsize\tsha256\ttarget_sha256\n'
        for row in "$@"; do
            printf '%s\n' "$row"
        done
    } > "$MIGRATIONS"
}
row_official_110() {
    printf '1.1\tSM8550\t%s\t%s\t%s' \
        "$blob_size" "$(hash_of "$official_110")" "$target_hash"
}
row_personal_100() {
    printf '1.0\tSM8550\t%s\t%s\t%s' \
        "$blob_size" "$(hash_of "$personal_100")" "$target_hash"
}

cat > "$WORK/bin/dd" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do case "$arg" in if=*) input=${arg#if=} ;; of=*) output=${arg#of=} ;; esac; done
if [[ "${input:-}" == "${ARMADA_TEST_PAYLOAD}" ]]; then
    printf '%s\n' "$output" >> "$ARMADA_TEST_WRITE_LOG"
    [[ "${ARMADA_TEST_DD_FAIL:-0}" != 1 ]] || exit 1
fi
exec /usr/bin/dd "$@"
EOF
chmod +x "$WORK/bin/dd"
cat > "$WORK/splash" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARMADA_TEST_SPLASH_LOG"
EOF
chmod +x "$WORK/splash"

ABL_A="$WORK/abl_a"
ABL_B="$WORK/abl_b"
SOC_ID="$WORK/soc_id"
EFIVARS="$WORK/efivars"
WRITES="$WORK/writes"
LOADER_INFO="$EFIVARS/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

base_env=(
    ARMADA_ABL_TESTING=1
    ARMADA_ABL_DEVICE_ID=armada-abl-migration-test
    ARMADA_ABL_SOC=SM8550
    ARMADA_ABL_A="$ABL_A"
    ARMADA_ABL_B="$ABL_B"
    ARMADA_ABL_LOCK="$WORK/lock"
    ARMADA_TEST_PAYLOAD="$PAYLOAD"
    ARMADA_TEST_WRITE_LOG="$WRITES"
    ARMADA_TEST_SPLASH_LOG="$WORK/splash-log"
    ARMADA_EFIVARS="$EFIVARS"
    ARMADA_ESRT="$WORK/esrt"
    ARMADA_ABL_SOC_ID_PATH="$SOC_ID"
    ABL_VERSION_TOOL="$VERSION_TOOL"
    ARMADA_ABL_RELEASES="$CATALOG"
    SPLASH="$WORK/splash"
    PATH="$WORK/bin:$PATH"
)

run_update() { env "${base_env[@]}" "$UPDATE" --target-root "$TARGET" 2>&1; }
env "${base_env[@]}" python3 "$VERSION_TOOL" --firmware >/dev/null 2>&1 &&
    die "fixture unexpectedly reports running firmware"
set_loader_info() {
    mkdir -p "$EFIVARS"
    python3 - "$LOADER_INFO" "$1" <<'PY'
import sys

path, text = sys.argv[1:]
with open(path, "wb") as output:
    output.write(b"\x06\x00\x00\x00" + (text + "\0").encode("utf-16-le"))
PY
}
install_both() { cp "$1" "$ABL_A"; cp "$1" "$ABL_B"; : > "$WRITES"; }
install_mixed() { cp "$1" "$ABL_A"; cp "$2" "$ABL_B"; : > "$WRITES"; }
reset_fixture() {
    rm -f "$MIGRATIONS"
    rm -rf "$EFIVARS" "$WORK/esrt"
    printf '601\n' > "$SOC_ID"
    : > "$WRITES"
}
signature() { sha256sum "$ABL_A" "$ABL_B" | cut -d' ' -f1 | tr '\n' ' '; }

assert_written() { # tag
    local tag=$1
    cmp -s "$PAYLOAD" "$ABL_A" ||
        { fail_msg "$tag" "ABL A does not hold exactly the target payload"; return 1; }
    cmp -s "$PAYLOAD" "$ABL_B" ||
        { fail_msg "$tag" "ABL B does not hold exactly the target payload"; return 1; }
    printf '%s\n%s\n' "$ABL_A" "$ABL_B" | cmp -s - "$WRITES" ||
        { fail_msg "$tag" "expected abl_a-then-abl_b writes, got: $(tr '\n' ' ' < "$WRITES")"; return 1; }
    return 0
}
assert_untouched() { # tag before-signature
    local tag=$1 before=$2
    [[ ! -s "$WRITES" ]] ||
        { fail_msg "$tag" "unexpected write: $(tr '\n' ' ' < "$WRITES")"; return 1; }
    [[ "$(signature)" == "$before" ]] ||
        { fail_msg "$tag" "ABL partition bytes changed"; return 1; }
    return 0
}
expect_refused() { # tag out rc before-signature
    local tag=$1 out=$2 rc=$3 before=$4 ok=0
    [[ $rc -ne 0 ]] || { fail_msg "$tag" "expected a refusal, updater exited 0: $out"; ok=1; }
    assert_untouched "$tag" "$before" || ok=1
    return $ok
}

# 1. Official 1.1 matching an approved row migrates to the personal payload.
#    Red today: check_installed rejects a same-version payload with other bytes.
case01() {
    reset_fixture
    install_both "$official_110"
    write_migrations "$(row_official_110)" "$(row_personal_100)"
    local out rc
    out=$(run_update); rc=$?
    [[ $rc -eq 0 ]] ||
        { fail_msg case01 "expected the approved 1.1 migration, updater exited $rc: $out"; return 1; }
    assert_written case01
}

# 2. Old personal 1.0 (absent from the catalog) matching an approved row
#    migrates without any firmware report.
#    Red today: the image is unknown and there is nothing vouching for it.
case02() {
    reset_fixture
    install_both "$personal_100"
    write_migrations "$(row_official_110)" "$(row_personal_100)"
    local out rc
    out=$(run_update); rc=$?
    [[ $rc -eq 0 ]] ||
        { fail_msg case02 "expected the approved 1.0 migration, updater exited $rc: $out"; return 1; }
    assert_written case02
}

# 3. Already carrying the target payload: success without any write.
case03() {
    reset_fixture
    install_both "$PAYLOAD"
    write_migrations "$(row_official_110)" "$(row_personal_100)"
    local before out rc
    before=$(signature)
    out=$(run_update); rc=$?
    [[ $rc -eq 0 ]] || { fail_msg case03 "noop returned $rc: $out"; return 1; }
    assert_untouched case03 "$before"
}

# 4. Same official version without the migration table is refused.
case04() {
    reset_fixture
    install_both "$official_110"
    local before out rc
    before=$(signature)
    out=$(run_update); rc=$?
    expect_refused case04 "$out" "$rc" "$before"
}

# 5. An approved source row bound to another target digest authorizes nothing.
case05() {
    reset_fixture
    install_both "$official_110"
    write_migrations "$(printf '1.1\tSM8550\t%s\t%s\t%s' \
        "$blob_size" "$(hash_of "$official_110")" "$(hash_of "$newer_120")")"
    local before out rc
    before=$(signature)
    out=$(run_update); rc=$?
    expect_refused case05 "$out" "$rc" "$before"
}

# 6. Unknown same-version bytes while OpenABL 1.1 is running: never overwritten.
case06() {
    reset_fixture
    install_both "$unknown_110"
    set_loader_info "OpenABL 1.1"
    local before
    before=$(signature)
    run_update >/dev/null
    assert_untouched case06 "$before"
}

# 7. A listed newer 1.2 stays, even when a forged row allows it.
case07() {
    reset_fixture
    install_both "$newer_120"
    write_migrations "$(printf '1.2\tSM8550\t%s\t%s\t%s' \
        "$blob_size" "$(hash_of "$newer_120")" "$target_hash")"
    local before out rc
    before=$(signature)
    out=$(run_update); rc=$?
    expect_refused case07 "$out" "$rc" "$before"
}

# 8. Source bytes for another SoC are refused.
case08() {
    reset_fixture
    install_both "$wrong_soc"
    write_migrations "$(row_official_110)" "$(row_personal_100)"
    local before out rc
    before=$(signature)
    out=$(run_update); rc=$?
    expect_refused case08 "$out" "$rc" "$before"
}

# 9. A target payload tampered after the manifest hash was written is refused.
case09() {
    reset_fixture
    install_both "$official_110"
    write_migrations "$(row_official_110)"
    cp "$PAYLOAD" "$WORK/payload.good"
    python3 - "$PAYLOAD" <<'PY'
import sys

with open(sys.argv[1], "r+b") as image:
    first = image.read(1)
    image.seek(0)
    image.write(bytes([first[0] ^ 0x01]))
PY
    local before out rc ok=0
    before=$(signature)
    out=$(run_update); rc=$?
    expect_refused case09 "$out" "$rc" "$before" || ok=1
    cp "$WORK/payload.good" "$PAYLOAD"
    return $ok
}

# 10. Modified bytes of an approved source are never overwritten; the running
#     report stays at 1.1 so the older-running fallback cannot kick in.
case10() {
    reset_fixture
    cp "$official_110" "$WORK/modified-1.1"
    python3 - "$WORK/modified-1.1" <<'PY'
import sys

with open(sys.argv[1], "r+b") as image:
    image.seek(-1, 2)
    last = image.read(1)
    image.seek(-1, 2)
    image.write(bytes([last[0] ^ 0x01]))
PY
    install_both "$WORK/modified-1.1"
    write_migrations "$(row_official_110)" "$(row_personal_100)"
    set_loader_info "OpenABL 1.1"
    local before
    before=$(signature)
    run_update >/dev/null
    assert_untouched case10 "$before"
}

# 11. One approved source and one unknown same-version copy: no partial write.
case11() {
    reset_fixture
    install_mixed "$official_110" "$unknown_110"
    write_migrations "$(row_official_110)" "$(row_personal_100)"
    local before out rc ok=0
    before=$(signature)
    out=$(run_update); rc=$?
    [[ $rc -ne 0 ]] ||
        { fail_msg case11 "expected a refusal for the unknown copy, updater exited 0: $out"; ok=1; }
    assert_untouched case11 "$before" || ok=1
    return $ok
}

# 12. An approved source prefix inside a larger partition migrates and keeps the
#     ordinary dd notrunc tail; the 1.0 report keeps this path eligible today.
case12() {
    reset_fixture
    python3 - "$personal_100" "$WORK/source-with-tail" "$WORK/tail.bin" <<'PY'
import sys

source_path, image_path, tail_path = sys.argv[1:]
tail = b"stale partition tail" * 300
with open(tail_path, "wb") as output:
    output.write(tail)
with open(source_path, "rb") as source, open(image_path, "wb") as output:
    output.write(source.read())
    output.write(tail)
PY
    local tail_size
    tail_size=$(stat -c %s "$WORK/tail.bin")
    install_both "$WORK/source-with-tail"
    write_migrations "$(row_personal_100)"
    set_loader_info "OpenABL 1.0"
    local out rc ok=0 part
    out=$(run_update); rc=$?
    [[ $rc -eq 0 ]] ||
        { fail_msg case12 "expected the approved prefix migration, updater exited $rc: $out"; return 1; }
    for part in "$ABL_A" "$ABL_B"; do
        cmp -s -n "$target_size" "$PAYLOAD" "$part" ||
            { fail_msg case12 "${part##*/} prefix is not the target payload"; ok=1; }
        tail -c "$tail_size" "$part" | cmp -s - "$WORK/tail.bin" ||
            { fail_msg case12 "${part##*/} lost its partition tail"; ok=1; }
    done
    return $ok
}

total=0
passed=0
failed=0
run_case() {
    local fn=$1 label=$2
    total=$((total + 1))
    if "$fn"; then
        printf 'PASS %s\n' "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$label"
        failed=$((failed + 1))
    fi
}

run_case case01 "case01 official 1.1 approved row -> personal payload"
run_case case02 "case02 old personal 1.0 approved row without firmware report"
run_case case03 "case03 already target -> noop"
run_case case04 "case04 official same version without migration table -> refused"
run_case case05 "case05 approved row bound to another target -> refused"
run_case case06 "case06 unknown same version, OpenABL 1.1 running -> no overwrite"
run_case case07 "case07 forged row claiming newer 1.2 -> refused"
run_case case08 "case08 wrong-SoC source bytes -> refused"
run_case case09 "case09 tampered target payload -> refused"
run_case case10 "case10 modified approved source -> no overwrite"
run_case case11 "case11 approved A with unknown B -> no writes"
run_case case12 "case12 approved prefix with larger partition -> tail retained"

printf '\n%d cases: %d passed, %d failed\n' "$total" "$passed" "$failed"
(( failed == 0 )) || exit 1
