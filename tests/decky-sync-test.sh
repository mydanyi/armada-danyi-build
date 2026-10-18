#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/system_files/usr/lib/decky-loader/armada-decky-sync"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/bundled" "$WORK/homebrew/services" "$WORK/plugins"
cat > "$WORK/bin/chcon" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin/chcon"

sed \
    -e "s|user_name=armada|user_name=$(id -un)|" \
    -e "s|homebrew=\"/var/home/\${user_name}/homebrew\"|homebrew=\"$WORK/homebrew\"|" \
    -e "s|loader_src=/usr/share/decky-loader/PluginLoader|loader_src=$WORK/bundled/PluginLoader|" \
    -e "s|loader_version_src=/usr/share/decky-loader/.loader.version|loader_version_src=$WORK/bundled/.loader.version|" \
    -e "s|src=/usr/share/decky-plugins|src=$WORK/plugins|" \
    -e "s|plugin_seed=/usr/lib/decky-loader/armada-plugin-seed.py|plugin_seed=$ROOT/system_files/usr/lib/decky-loader/armada-plugin-seed.py|" \
    "$SYNC" > "$WORK/sync"
chmod +x "$WORK/sync"

run_case() {
    local name=$1 installed=$2 bundled=$3 expected=$4
    printf '%s\n' "$installed" > "$WORK/homebrew/services/.loader.version"
    printf 'installed %s\n' "$installed" > "$WORK/homebrew/services/PluginLoader"
    chmod +x "$WORK/homebrew/services/PluginLoader"
    printf '%s\n' "$bundled" > "$WORK/bundled/.loader.version"
    printf 'bundled %s\n' "$bundled" > "$WORK/bundled/PluginLoader"
    chmod +x "$WORK/bundled/PluginLoader"

    PATH="$WORK/bin:$PATH" "$WORK/sync"
    actual=$(<"$WORK/homebrew/services/.loader.version")
    [[ "$actual" == "$expected" ]] ||
        fail "$name: expected $expected, got $actual"
    actual=$(<"$WORK/homebrew/services/PluginLoader")
    if [[ "$expected" == "$bundled" && "$installed" != "$bundled" ]]; then
        [[ "$actual" == "bundled $bundled" ]] ||
            fail "$name: expected bundled loader, got $actual"
    else
        [[ "$actual" == "installed $installed" ]] ||
            fail "$name: expected installed loader, got $actual"
    fi
}

run_case final-replaces-prerelease v3.2.8-pre1 v3.2.8 v3.2.8
run_case older-prerelease-does-not-replace-final v3.2.8 v3.2.8-pre1 v3.2.8
run_case newer-prerelease-replaces-final v3.2.8 v3.2.9-pre1 v3.2.9-pre1
run_case older-release-does-not-replace-newer v3.2.9 v3.2.8 v3.2.9
run_case newer-prerelease-replaces-older v3.2.8-pre1 v3.2.8-pre2 v3.2.8-pre2
run_case equal-version-preserves-loader v3.2.8 v3.2.8 v3.2.8

write_plugin() {
    local dir=$1 name=$2 version=$3 marker
    marker=${4:-$name-$version}
    mkdir -p "$dir/dist"
    printf '{"name":"%s","version":"%s"}\n' "$name" "$version" >"$dir/package.json"
    printf '{"name":"%s"}\n' "$name" >"$dir/plugin.json"
    printf 'main:%s\n' "$marker" >"$dir/main.py"
    printf 'js:%s\n' "$marker" >"$dir/dist/index.js"
}

reset_plugins() {
    rm -rf "$WORK/plugins" "$WORK/homebrew/plugins" "$WORK/homebrew/settings"
    mkdir -p "$WORK/plugins" "$WORK/homebrew/settings"
}

sync_plugins() {
    printf 'v3.2.8\n' >"$WORK/homebrew/services/.loader.version"
    printf 'installed v3.2.8\n' >"$WORK/homebrew/services/PluginLoader"
    chmod +x "$WORK/homebrew/services/PluginLoader"
    printf 'v3.2.8\n' >"$WORK/bundled/.loader.version"
    printf 'bundled v3.2.8\n' >"$WORK/bundled/PluginLoader"
    chmod +x "$WORK/bundled/PluginLoader"
    PATH="$WORK/bin:$PATH" "$WORK/sync"
}

assert_exists() { [[ -e "$1" ]] || fail "missing file: $1"; }

assert_content() {
    assert_exists "$1"
    local actual
    actual=$(<"$1")
    [[ "$actual" == "$2" ]] || fail "unexpected content in $1: $actual"
}

reset_plugins
write_plugin "$WORK/plugins/demo" demo 0.1.0
sync_plugins
for file in package.json plugin.json main.py dist/index.js; do
    assert_exists "$WORK/homebrew/plugins/demo/${file}"
done
assert_content "$WORK/homebrew/plugins/demo/package.json" '{"name":"demo","version":"0.1.0"}'

# Old mirror-only script reverts the installed 0.3.0 to bundled 0.1.0: expected first red failure.
printf '{"name":"demo","version":"0.3.0"}\n' >"$WORK/homebrew/plugins/demo/package.json"
printf 'main:user newer\n' >"$WORK/homebrew/plugins/demo/main.py"
printf 'user note\n' >"$WORK/homebrew/plugins/demo/USER-NOTE.txt"
sync_plugins
assert_content "$WORK/homebrew/plugins/demo/package.json" '{"name":"demo","version":"0.3.0"}'
assert_content "$WORK/homebrew/plugins/demo/main.py" 'main:user newer'
assert_content "$WORK/homebrew/plugins/demo/USER-NOTE.txt" 'user note'

reset_plugins
write_plugin "$WORK/plugins/other" other 0.1.0 first
sync_plugins
printf 'main:user edit\n' >"$WORK/homebrew/plugins/other/main.py"
printf 'user extra\n' >"$WORK/homebrew/plugins/other/user-extra.txt"
write_plugin "$WORK/plugins/other" other 0.1.0 changed
sync_plugins
assert_content "$WORK/homebrew/plugins/other/package.json" '{"name":"other","version":"0.1.0"}'
assert_content "$WORK/homebrew/plugins/other/main.py" 'main:user edit'
assert_content "$WORK/homebrew/plugins/other/user-extra.txt" 'user extra'

reset_plugins
write_plugin "$WORK/plugins/auto" auto 0.1.0 first
sync_plugins
write_plugin "$WORK/plugins/auto" auto 0.1.0 second
sync_plugins
assert_content "$WORK/homebrew/plugins/auto/main.py" 'main:second'
before=$(stat -c '%i %y' "$WORK/homebrew/plugins/auto/main.py")
sync_plugins
after=$(stat -c '%i %y' "$WORK/homebrew/plugins/auto/main.py")
[[ "$before" == "$after" ]] || fail "idempotent sync rewrote unchanged main.py"

reset_plugins
write_plugin "$WORK/homebrew/plugins/legacy" legacy 0.1.0 old-install
write_plugin "$WORK/plugins/legacy" legacy 0.2.0 new-bundle
sync_plugins
assert_content "$WORK/homebrew/plugins/legacy/package.json" '{"name":"legacy","version":"0.2.0"}'
assert_content "$WORK/homebrew/plugins/legacy/main.py" 'main:new-bundle'

reset_plugins
write_plugin "$WORK/homebrew/plugins/custom" custom 0.1.0 local-custom
write_plugin "$WORK/plugins/custom" custom 0.1.0 bundle-custom
sync_plugins
assert_content "$WORK/homebrew/plugins/custom/main.py" 'main:local-custom'

reset_plugins
write_plugin "$WORK/plugins/cache" cache 0.1.0 v1
sync_plugins
mkdir -p "$WORK/homebrew/plugins/cache/__pycache__"
printf 'bytecode\n' >"$WORK/homebrew/plugins/cache/__pycache__/main.cpython-311.pyc"
write_plugin "$WORK/plugins/cache" cache 0.1.0 v2
sync_plugins
assert_content "$WORK/homebrew/plugins/cache/main.py" 'main:v2'

reset_plugins
write_plugin "$WORK/plugins/demo" demo 0.1.0
printf '{\n  "branch": 0\n}\n' >"$WORK/homebrew/settings/loader.json"
mkdir -p "$WORK/homebrew/settings/demo"
printf 'plugin setting\n' >"$WORK/homebrew/settings/demo/config.json"
write_plugin "$WORK/homebrew/plugins/keepme" keepme 0.1.0 keep
sync_plugins
assert_content "$WORK/homebrew/settings/loader.json" '{
  "branch": 0
}'
assert_content "$WORK/homebrew/settings/demo/config.json" 'plugin setting'
assert_content "$WORK/homebrew/plugins/keepme/main.py" 'main:keep'

# Architecture-aware same-version migration.
write_elf() {
    local path=$1 machine=$2 marker=$3
    mkdir -p "$(dirname -- "$path")"
    python3 - "$path" "$machine" "$marker" <<'PY'
import struct
import sys

path, machine, marker = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\x00" * 8
header = ident + struct.pack(
    "<HHIQQQIHHHHHH",
    2,        # e_type: ET_EXEC
    machine,  # e_machine: 183 AArch64, 62 x86-64
    1,        # e_version
    0x400000, 64, 0, 0, 64, 56, 1, 0, 0, 0,
)
phdr = struct.pack("<IIQQQQQQ", 1, 4, 0, 0x400000, 0x400000, 0, 0, 0x1000)
with open(path, "wb") as handle:
    handle.write(header + phdr + marker.encode() + b"\n")
PY
    chmod +x "$path"
}

# Same version, installed x86-64: the bundled native AArch64 must replace it.
reset_plugins
write_elf "$WORK/homebrew/services/PluginLoader" 62 installed-x86
printf 'v3.3.0\n' >"$WORK/homebrew/services/.loader.version"
write_elf "$WORK/bundled/PluginLoader" 183 bundled-arm64
printf 'v3.3.0\n' >"$WORK/bundled/.loader.version"
PATH="$WORK/bin:$PATH" "$WORK/sync"
assert_content "$WORK/homebrew/services/.loader.version" 'v3.3.0'
cmp -s "$WORK/homebrew/services/PluginLoader" "$WORK/bundled/PluginLoader" ||
    fail "same-version installed x86-64 loader was not replaced by bundled AArch64"

# Same version, installed native AArch64: preserve inode and exact bytes.
reset_plugins
write_elf "$WORK/homebrew/services/PluginLoader" 183 installed-arm64
printf 'v3.3.0\n' >"$WORK/homebrew/services/.loader.version"
cp "$WORK/homebrew/services/PluginLoader" "$WORK/preserved-arm64"
before=$(stat -c '%i %y' "$WORK/homebrew/services/PluginLoader")
write_elf "$WORK/bundled/PluginLoader" 183 bundled-arm64
printf 'v3.3.0\n' >"$WORK/bundled/.loader.version"
PATH="$WORK/bin:$PATH" "$WORK/sync"
after=$(stat -c '%i %y' "$WORK/homebrew/services/PluginLoader")
[[ "$before" == "$after" ]] || fail "same-version native AArch64 loader was rewritten"
cmp -s "$WORK/homebrew/services/PluginLoader" "$WORK/preserved-arm64" ||
    fail "same-version native AArch64 loader content changed"
assert_content "$WORK/homebrew/services/.loader.version" 'v3.3.0'

# Newer installed x86-64 must not be downgraded to an older bundled ARM64.
reset_plugins
write_elf "$WORK/homebrew/services/PluginLoader" 62 installed-x86-newer
printf 'v3.4.0\n' >"$WORK/homebrew/services/.loader.version"
cp "$WORK/homebrew/services/PluginLoader" "$WORK/preserved-x86-newer"
before=$(stat -c '%i %y' "$WORK/homebrew/services/PluginLoader")
write_elf "$WORK/bundled/PluginLoader" 183 bundled-arm64-older
printf 'v3.3.0\n' >"$WORK/bundled/.loader.version"
PATH="$WORK/bin:$PATH" "$WORK/sync"
after=$(stat -c '%i %y' "$WORK/homebrew/services/PluginLoader")
assert_content "$WORK/homebrew/services/.loader.version" 'v3.4.0'
[[ "$before" == "$after" ]] || fail "newer installed x86-64 loader was rewritten"
cmp -s "$WORK/homebrew/services/PluginLoader" "$WORK/preserved-x86-newer" ||
    fail "newer installed x86-64 loader was downgraded to bundled ARM64"

printf 'decky sync tests passed\n'
