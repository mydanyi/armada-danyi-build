#!/usr/bin/env bash
# update.sh — 下载 armada 分卷 OCI 归档，逐卷校验、合并校验后交给 bootc switch
#
# 用法:
#   sudo ./update.sh                 # 取 GitHub 最新 release 的 tag（CLI 交互更新）
#   sudo ./update.sh <release-tag>   # 显式指定 tag（CLI 交互更新）
#   sudo ./update.sh --check [tag]   # 只读预检：查询 release 元数据判断是否有新版本
#   sudo ./update.sh --steam [tag]   # Steam 图形更新：进度 N% 写 stdout，其余写 stderr
#
# 流程（默认 CLI 模式，保持既有行为不变）:
#   0. 只读预检（锁外）：root(EUID) / aarch64 / bootc status 可用 / 依赖命令
#      （curl、jq、sha256sum、systemd-inhibit）
#   1. 通过 systemd-inhibit 申请 idle:sleep 阻塞锁后，才在锁保护下执行主体
#   2. 解析 tag（参数优先，否则查 GitHub API 的 tag_name）
#   3. 在 /var/lib/armada-danyi-updates/<TAG>/ 内下载 SHA256SUMS
#   4. 严格识别其中唯一的 armada-*.oci.tar 及其 .partNNN 列表（拒绝目录路径、
#      异常文件名、多个 OCI 完整包、非 64 位十六进制哈希）
#   5. 按 part 编号排序逐个下载 -> 每个分卷 sha256sum -c 通过 -> 合并为 .pending
#      -> 校验完整 OCI 的 SHA256 -> mv 为正名
#   6. bootc switch --transport oci-archive <归档>
#
# --check [tag]（只读、不申请 inhibitor、不做任何修改）:
#   * 仍执行 root / aarch64 / bootc + 依赖的只读预检
#   * 查询 GitHub releases/latest（或给定 tag），仅取该 tag 下的
#     oci-image-info.json（skopeo inspect JSON），严格校验：
#       Architecture == arm64、Os == linux、Digest 为 sha256:<64hex>、
#       Labels containers.bootc == "1"、Labels org.opencontainers.image.version
#       为安全版本字符串，且 TAG 严格等于 v+version
#   * 用 `bootc status --format json` 的 status.booted / status.staged 的
#     image.version 与 image.imageDigest 判断目标是否已安装或已暂存
#   * 待更新：打印目标 version 一行 -> exit 0
#     已暂存：打印已暂存 version 一行（供 Steam 显示重启待定）-> exit 0
#     已是最新且无暂存：无 stdout -> exit 7
#     网络失败 / 无元数据 / 架构、bootc、version、tag、digest 不合法 /
#     无法读取 booted 状态：stderr 诊断、stdout 空 -> exit 7
#   * 不下载任何 OCI 分卷、不建立大缓存、不自动回退到官方更新
#
# --steam [tag]（Steam 图形更新，在 idle:sleep 锁内执行）:
#   * 正常日志写 stderr；stdout 只能是单调递增的 N%（0..100 整数）
#   * 在锁内才解析 Release、元数据、状态、下载、校验、合并、部署
#   * 已安装或已暂存目标时不重复下载分卷 / 不再 switch，成功 exit 0
#   * 下载 / 校验 / 合并 / bootc switch 任一失败：stderr 诊断 -> exit 7，
#     绝不打印假 100%
#   * 从 SHA256SUMS 解析出的唯一完整 OCI 名必须与元数据 version 匹配
#     armada-<version>.oci.tar；完整 hash 与每卷 hash 仍是部署前的实际校验
#
# 电源保护:
#   * 默认 CLI 与 --steam 的下载 / 校验 / 合并 / 部署由 systemd-inhibit 的
#     idle:sleep 阻塞锁保护，流程结束、失败或被中断时锁自动释放
#   * --check 只读且不改动系统，故不申请该锁
#   * 不修改用户的任何电源设置，不安装后台服务
#   * Steam 游戏模式下的实际屏幕保持仍待真机验收，本脚本不对此作出保证
#
# 安全约束:
#   * 绝不传 --apply，绝不 reboot / systemctl reboot；重启由用户手动完成
#   * 任何下载失败、哈希不符、缺卷都会非 0 退出，且不会调用 bootc switch
#   * 电源抑制锁申请失败时不进行任何网络请求或缓存写入，也不会调用 bootc switch
#   * 默认 CLI 只写 /var/lib/armada-danyi-updates/<TAG>/；唯一另外的状态写入是
#     update_main 在 bootc switch 成功后对已存在的
#     /var/lib/armada/personal-update-channel 写回 danyi（文件不存在则不创建）。
#     不删旧更新与其他资源，不接触游戏与存档；真实 OCI 校验由 bootc 导入执行
#   * --check / --steam 不自动回退到官方更新
#   * 不设置也不覆写 HOME / CODEX_HOME
set -euo pipefail

CACHE_ROOT=/var/lib/armada-danyi-updates
# 从官方版本切回个人版后唯一需要复原的渠道选择文件（仅在它已存在时写回）。
PERSONAL_CHANNEL_FILE=/var/lib/armada/personal-update-channel
REPO_SLUG=mydanyi/armada-danyi-build
API_LATEST="https://api.github.com/repos/${REPO_SLUG}/releases/latest"
DOWNLOAD_BASE="https://github.com/${REPO_SLUG}/releases/download"
INFO_NAME=oci-image-info.json

MODE=update

# 失败退出：--check/--steam 严格映射到 7（Steam 协议），默认 CLI 保持既有非零语义。
fatal() {
  printf 'update: 错误: %s\n' "$*" >&2
  case ${MODE:-update} in
    check|steam) exit 7 ;;
    *) exit 1 ;;
  esac
}

# 正常日志：默认 CLI 写 stdout（保持原行为）；--check/--steam 写 stderr。
info() {
  if [ "${MODE:-update}" = update ]; then
    printf 'update: %s\n' "$*"
  else
    printf 'update: %s\n' "$*" >&2
  fi
}

# 进度输出：仅 --steam 模式写 stdout，且只能是 N%（0..100 整数）。
report_progress() {
  [ "${MODE:-update}" = steam ] || return 0
  printf '%s%%\n' "$1"
}

# ----------------------------------------------------------- 参数解析

if [ "$#" -ge 1 ]; then
  case $1 in
    --check) MODE=check; shift ;;
    --steam) MODE=steam; shift ;;
  esac
fi
[ "$#" -le 1 ] || fatal "用法: $0 [--check|--steam] [release-tag]"
TAG_ARG=${1:-}

# ----------------------------------------------------------- 运行环境检查（只读，锁外执行）

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  fatal "需要 root 权限，请使用 sudo 运行"
fi

ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || fatal "本脚本只支持 aarch64，当前架构: $ARCH"

command -v bootc >/dev/null 2>&1 || fatal "未找到 bootc 命令"
bootc status >/dev/null 2>&1 || fatal "bootc status 执行失败，当前系统不是 bootc 主机"

# --check 只读且不申请锁，因此不强制要求 systemd-inhibit。
DEPS="curl jq sha256sum"
[ "$MODE" = check ] || DEPS="$DEPS systemd-inhibit"
for cmd in $DEPS; do
  command -v "$cmd" >/dev/null 2>&1 || fatal "缺少依赖命令: $cmd"
done

# ----------------------------------------------------------- 通用函数（锁外 / 锁内均可用）

# 解析 tag：参数优先，否则查 GitHub releases/latest。结果写入全局 TAG。
resolve_tag() {
  local arg=${1:-}
  if [ -n "$arg" ]; then
    TAG=$arg
    info "使用指定 tag: $TAG"
    return 0
  fi
  info "查询 GitHub 最新 release ..."
  TAG=$(curl -fsSL --retry 3 "$API_LATEST" | jq -r '.tag_name // empty') \
    || fatal "查询 GitHub API 失败"
  [ -n "$TAG" ] || fatal "GitHub API 未返回 tag_name"
  info "最新 tag: $TAG"
}

# tag 安全校验：字母数字开头；其余只允许字母数字点横线下划线（无斜杠、无空白）。
validate_tag() {
  case $1 in
    [A-Za-z0-9]*) : ;;
    *) fatal "非法 tag（必须以字母数字开头）: '$1'" ;;
  esac
  case $1 in
    *[!A-Za-z0-9._-]*) fatal "非法 tag（只允许字母数字点横线下划线，禁止斜杠与空白）: '$1'" ;;
  esac
}

# 取该 tag 下的发布元数据并严格校验；成功设置全局 META_VERSION / META_DIGEST。
# 只读、不下载分卷、不写缓存——元数据很小，仅在内存中校验。
fetch_metadata() {
  local tag=$1 url json
  url="$DOWNLOAD_BASE/$tag/$INFO_NAME"
  info "获取发布元数据 $INFO_NAME（$tag）..."
  json=$(curl -fsSL --retry 3 "$url") \
    || fatal "无法获取发布元数据：release 未提供 $INFO_NAME（当前 release 未支持图形更新）"
  [ -n "$json" ] || fatal "发布元数据为空"
  validate_metadata_json "$tag" "$json"
}

validate_metadata_json() {
  local tag=$1 json=$2 arch os digest bootc version
  # 先严格确定顶层是 JSON object，再要求 Labels 是 object：类型不符必须经 fatal
  # 归一到协议退出码（--check/--steam -> 7），绝不能让 jq 自身的类型错误码
  #（例如 5）作为脚本退出码泄漏出去。
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || fatal "发布元数据不是合法 JSON 对象"
  printf '%s' "$json" | jq -e '.Labels | type == "object"' >/dev/null 2>&1 \
    || fatal "发布元数据 Labels 不是 JSON 对象"
  arch=$(printf '%s' "$json" | jq -r '.Architecture // empty')
  [ "$arch" = "arm64" ] || fatal "发布元数据 Architecture='$arch'，期望 arm64"
  os=$(printf '%s' "$json" | jq -r '.Os // empty')
  [ "$os" = "linux" ] || fatal "发布元数据 Os='$os'，期望 linux"
  digest=$(printf '%s' "$json" | jq -r '.Digest // empty')
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fatal "发布元数据 Digest 非法: '$digest'"
  bootc=$(printf '%s' "$json" | jq -r '.Labels["containers.bootc"] // empty')
  [ "$bootc" = "1" ] || fatal "发布元数据 containers.bootc='$bootc'，期望 1"
  version=$(printf '%s' "$json" | jq -r '.Labels["org.opencontainers.image.version"] // empty')
  [ -n "$version" ] || fatal "发布元数据缺少 org.opencontainers.image.version"
  [[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fatal "发布元数据 version 非法: '$version'"
  [ "$tag" = "v$version" ] \
    || fatal "release tag '$tag' 与发布元数据 version '$version' 不一致（要求 tag=v+version）"
  META_VERSION=$version
  META_DIGEST=$digest
}

# 读取实际 bootc 状态；设置 BOOTED_/STAGED_ 的 version 与 imageDigest。
read_bootc_state() {
  local json
  json=$(bootc status --format json) || fatal "无法读取 bootc status"
  [ -n "$json" ] || fatal "bootc status 输出为空"
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || fatal "bootc status 输出不是合法 JSON"
  BOOTED_VERSION=$(printf '%s' "$json" | jq -r '.status.booted.image.version // empty')
  BOOTED_DIGEST=$(printf '%s' "$json" | jq -r '.status.booted.image.imageDigest // empty')
  [ -n "$BOOTED_VERSION" ] || [ -n "$BOOTED_DIGEST" ] || fatal "无法从 bootc status 读取已启动部署"
  STAGED_VERSION=
  STAGED_DIGEST=
  if [ "$(printf '%s' "$json" | jq -r '.status.staged | type')" = "object" ]; then
    STAGED_VERSION=$(printf '%s' "$json" | jq -r '.status.staged.image.version // empty')
    STAGED_DIGEST=$(printf '%s' "$json" | jq -r '.status.staged.image.imageDigest // empty')
  fi
}

# 目标是否已安装/已暂存：version 或 digest 命中元数据即视为一致。
matches_target() {
  local v=${1:-} d=${2:-}
  if [ -n "$v" ] && [ "$v" = "$META_VERSION" ]; then return 0; fi
  if [ -n "$d" ] && [ "$d" = "$META_DIGEST" ]; then return 0; fi
  return 1
}

# ----------------------------------------------------------- 下载 / 校验 / 合并引擎（锁内）
# 用法: download_verify_merge <tag> [expected_oci_name]
#   expected_oci_name 为空时保持旧 CLI 行为（不强制与元数据版本匹配，
#   旧 release 不含小 metadata 仍可升级）；非空时要求 SHA256SUMS 的唯一完整
#   包名与之严格相等。成功后设置全局 OCI_ARCHIVE。
download_verify_merge() {
  local tag=$1 expected=${2:-}
  local CACHE=$CACHE_ROOT/$tag
  local SUMS_FILE=$CACHE/SHA256SUMS
  local PARTS_RAW=$CACHE/.oci-parts.raw
  local PARTS_SORTED=$CACHE/.oci-parts.sorted
  local OCI_NAME= OCI_HASH= oci_count=0 part_count=0
  local line h n num name hash idx

  mkdir -p "$CACHE" || fatal "无法创建缓存目录: $CACHE"
  info "缓存目录: $CACHE"

  info "下载 SHA256SUMS ..."
  curl -fsSL --retry 3 -o "$SUMS_FILE" "$DOWNLOAD_BASE/$tag/SHA256SUMS" \
    || fatal "下载 SHA256SUMS 失败"
  [ -s "$SUMS_FILE" ] || fatal "SHA256SUMS 为空"

  : > "$PARTS_RAW"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in
      ''|'#'*) continue ;;
    esac

    h=${line%%[[:space:]]*}
    n=${line#"$h"}
    n=${n#" "}
    n=${n#" "}
    n=${n#\*}
    [ -n "$h" ] && [ -n "$n" ] || continue

    if [[ $n =~ ^armada-[A-Za-z0-9._-]+\.oci\.tar$ ]]; then
      [[ $h =~ ^[0-9a-fA-F]{64}$ ]] || fatal "SHA256SUMS 中 '$n' 的哈希不是 64 位十六进制"
      oci_count=$((oci_count + 1))
      [ "$oci_count" -eq 1 ] || fatal "SHA256SUMS 含多个 OCI 完整包（'$OCI_NAME' 与 '$n'），拒绝"
      OCI_NAME=$n
      OCI_HASH=$h
    elif [[ $n =~ ^armada-[A-Za-z0-9._-]+\.oci\.tar\.part[0-9]{3,}$ ]]; then
      [[ $h =~ ^[0-9a-fA-F]{64}$ ]] || fatal "SHA256SUMS 中 '$n' 的哈希不是 64 位十六进制"
      printf '%s %s %s\n' "${n##*part}" "$n" "$h" >> "$PARTS_RAW"
      part_count=$((part_count + 1))
    fi
  done < "$SUMS_FILE"

  [ "$oci_count" -eq 1 ] || fatal "SHA256SUMS 中必须恰好有 1 个 armada-*.oci.tar 完整包，实际 $oci_count 个"
  [ "$part_count" -gt 0 ] || fatal "SHA256SUMS 中没有分卷条目"
  info "完整包: $OCI_NAME"

  # 图形更新路径：唯一完整 OCI 名必须与发布元数据 version 匹配。
  if [ -n "$expected" ] && [ "$OCI_NAME" != "$expected" ]; then
    fatal "SHA256SUMS 完整包 '$OCI_NAME' 与发布元数据版本不匹配（期望 '$expected'）"
  fi

  # 只保留属于该完整包的分卷，并按 part 编号排序（防跨包分卷与伪造文件名）
  : > "$PARTS_SORTED"
  while read -r num name hash; do
    case $name in
      "$OCI_NAME".part[0-9][0-9][0-9]*)
        printf '%s %s %s\n' "$num" "$name" "$hash" >> "$PARTS_SORTED"
        ;;
    esac
  done < "$PARTS_RAW"

  [ -s "$PARTS_SORTED" ] || fatal "SHA256SUMS 中没有属于 $OCI_NAME 的分卷"

  sort -k1,1n -k2,2 "$PARTS_SORTED" > "$PARTS_SORTED.tmp"
  mv -f "$PARTS_SORTED.tmp" "$PARTS_SORTED"

  local EXPECTED=0 TOTAL_PARTS
  while read -r num name hash; do
    idx=$((10#$num))
    [ "$idx" -eq "$EXPECTED" ] \
      || fatal "分卷编号不连续（期望 $EXPECTED，实际 $num），可能缺卷或已被篡改"
    EXPECTED=$((EXPECTED + 1))
  done < "$PARTS_SORTED"
  TOTAL_PARTS=$EXPECTED
  info "分卷数量: $TOTAL_PARTS"

  # 逐卷下载并校验；按已校验分卷递增进度（--steam 才输出）
  local i=0
  while read -r num name hash; do
    info "下载分卷 $name"
    curl -fsSL --retry 3 -o "$CACHE/$name" "$DOWNLOAD_BASE/$tag/$name" \
      || fatal "下载分卷失败: $name"
    printf '%s  %s\n' "$hash" "$name" > "$CACHE/.part-check"
    ( cd "$CACHE" && sha256sum -c "$CACHE/.part-check" > /dev/null ) \
      || fatal "分卷校验失败（内容被篡改或传输损坏）: $name"
    i=$((i + 1))
    report_progress $(( 5 + 70 * i / TOTAL_PARTS ))
  done < "$PARTS_SORTED"
  rm -f "$CACHE/.part-check"

  # 合并与完整校验
  local PENDING=$CACHE/$OCI_NAME.pending ACTUAL
  info "合并分卷 -> $OCI_NAME.pending"
  : > "$PENDING"
  while read -r num name hash; do
    cat -- "$CACHE/$name" >> "$PENDING"
  done < "$PARTS_SORTED"

  ACTUAL=$(sha256sum "$PENDING" | cut -d' ' -f1)
  if [ "$ACTUAL" != "$OCI_HASH" ]; then
    rm -f -- "$PENDING"
    fatal "完整 OCI 校验失败（缺卷或内容被篡改），未执行 bootc switch"
  fi
  mv -f -- "$PENDING" "$CACHE/$OCI_NAME"
  info "OCI 归档校验通过: $CACHE/$OCI_NAME"

  OCI_ARCHIVE=$CACHE/$OCI_NAME
  report_progress 85
}

# ----------------------------------------------------------- 各模式主体（在锁内运行）

# 默认 CLI：与既有行为一致（不依赖小 metadata）。
update_main() {
  local tag_arg=${1:-}
  # 已获锁：仅在此处打印一次电源保护提示，不承诺 Steam 自身屏保一定受控。
  info "更新期间已启用电源保护，完成或退出后自动恢复。"

  resolve_tag "$tag_arg"
  validate_tag "$TAG"

  download_verify_merge "$TAG"

  info "调用 bootc switch（不 --apply、不重启）"
  bootc switch --transport oci-archive "$OCI_ARCHIVE" || fatal "bootc switch 失败"

  # 从官方更新切回个人版时，渠道选择文件可能仍停留在 stable/beta/preview。
  # 仅在 switch 成功后、且该文件已存在（-f）时写回 danyi；switch 失败不改原选择；
  # 选择文件写入失败则报错；文件不存在不创建（下一次 boot 默认即 danyi）。
  if [ -f "$PERSONAL_CHANNEL_FILE" ]; then
    printf 'danyi\n' > "$PERSONAL_CHANNEL_FILE" \
      || fatal "无法写回个人更新渠道文件: $PERSONAL_CHANNEL_FILE"
  fi

  printf '\n更新已准备完成，请手动重启；可用 sudo bootc status 查看\n'
}

# Steam 图形更新：stdout 只有 N%，正常日志在 stderr，任何失败 exit 7。
steam_main() {
  local tag_arg=${1:-}
  info "更新期间已启用电源保护，完成或退出后自动恢复。"
  report_progress 0

  # 仅在锁内解析 Release / 元数据 / 状态。
  resolve_tag "$tag_arg"
  validate_tag "$TAG"
  fetch_metadata "$TAG"
  read_bootc_state

  # 已安装或已暂存目标：不再下载分卷、不再 switch，直接成功返回。
  # 成功 no-op 也必须把进度流收敛到 100%，否则 Steam 侧会停在起始的 0%。
  if matches_target "$BOOTED_VERSION" "$BOOTED_DIGEST"; then
    info "目标版本 $META_VERSION 已安装，无需更新。"
    report_progress 100
    exit 0
  fi
  if matches_target "$STAGED_VERSION" "$STAGED_DIGEST"; then
    info "目标版本 $META_VERSION 已暂存，等待重启。"
    report_progress 100
    exit 0
  fi

  report_progress 5
  download_verify_merge "$TAG" "armada-$META_VERSION.oci.tar"

  info "调用 bootc switch（不 --apply、不重启）"
  # bootc switch 的输出一律走 stderr，保证 stdout 只有进度。
  bootc switch --transport oci-archive "$OCI_ARCHIVE" 1>&2 || fatal "bootc switch 失败"

  report_progress 100
  info "更新已准备完成，请手动重启；可用 sudo bootc status 查看"
  exit 0
}

# 只读预检 --check：不申请锁、不下载分卷、不做任何修改。
check_main() {
  local tag_arg=${1:-}
  resolve_tag "$tag_arg"
  validate_tag "$TAG"
  fetch_metadata "$TAG"
  read_bootc_state

  # 已暂存：优先按目标命中判定（含 bootc 省略可选 staged.image.version、
  # 仅凭 imageDigest 命中的情形）。输出重启待定版本一行；若 staged 无版本，
  # 回退输出元数据版本 ——绝不输出空行再 exit 0。
  if matches_target "$STAGED_VERSION" "$STAGED_DIGEST"; then
    if [ -n "$STAGED_VERSION" ]; then
      printf '%s\n' "$STAGED_VERSION"
    else
      printf '%s\n' "$META_VERSION"
    fi
    exit 0
  fi
  if matches_target "$BOOTED_VERSION" "$BOOTED_DIGEST"; then
    # 已是最新：若有暂存（其它版本）则报告重启待定，否则无 stdout 并 exit 7。
    if [ -n "$STAGED_VERSION" ]; then
      printf '%s\n' "$STAGED_VERSION"
      exit 0
    fi
    exit 7
  fi
  printf '%s\n' "$META_VERSION"
  exit 0
}

# 锁内分发器：根据模式调用对应主体（透传可选 tag）。
dispatch() {
  MODE=$1
  local tag=${2:-}
  case $MODE in
    steam) steam_main "$tag" ;;
    *)     update_main "$tag" ;;
  esac
}

# ----------------------------------------------------------- 入口

# 主体与其依赖的函数、变量必须在锁内子 shell 中可见。
export CACHE_ROOT REPO_SLUG API_LATEST DOWNLOAD_BASE INFO_NAME MODE TAG_ARG PERSONAL_CHANNEL_FILE
export -f fatal info report_progress resolve_tag validate_tag fetch_metadata \
  validate_metadata_json read_bootc_state matches_target download_verify_merge \
  update_main steam_main check_main dispatch

# --check 是只读预检，不申请电源锁，直接在当前进程中执行。
if [ "$MODE" = "check" ]; then
  check_main "$TAG_ARG"
  exit $?
fi

# 只有成功申请到 idle:sleep 阻塞锁后才会执行主体；锁申请失败则不进行任何
# 网络请求或缓存写入。锁在整个更新流程期间持有，退出/失败/中断时由 systemd 释放。
# --steam 的下载 / 校验 / 合并 / switch 失败在锁内由 fatal 映射为 7；锁申请本身
# 失败时沿用 systemd-inhibit 的返回码（调用方 armada-update 会再映射为 7）。
exec systemd-inhibit \
  --what=idle:sleep \
  --mode=block \
  --who='Armada Danyi Update' \
  --why='Armada update in progress' \
  bash -euo pipefail -c 'dispatch "$@"' armada-danyi-update "$MODE" "$TAG_ARG"
