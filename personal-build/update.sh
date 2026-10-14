#!/usr/bin/env bash
# update.sh — 下载 armada 分卷 OCI 归档，逐卷校验、合并校验后交给 bootc switch
#
# 用法:
#   sudo ./update.sh                 # 取 GitHub 最新 release 的 tag
#   sudo ./update.sh <release-tag>   # 显式指定 tag
#
# 流程:
#   1. 校验运行环境：root(EUID) / aarch64 / bootc status 可用
#   2. 解析 tag（参数优先，否则查 GitHub API 的 tag_name）
#   3. 在 /var/lib/armada-danyi-updates/<TAG>/ 内下载 SHA256SUMS
#   4. 严格识别其中唯一的 armada-*.oci.tar 及其 .partNNN 列表（拒绝目录路径、
#      异常文件名、多个 OCI 完整包、非 64 位十六进制哈希）
#   5. 按 part 编号排序逐个下载 -> 每个分卷 sha256sum -c 通过 -> 合并为 .pending
#      -> 校验完整 OCI 的 SHA256 -> mv 为正名
#   6. bootc switch --transport oci-archive <归档>
#
# 安全约束:
#   * 绝不传 --apply，绝不 reboot / systemctl reboot；重启由用户手动完成
#   * 任何下载失败、哈希不符、缺卷都会非 0 退出，且不会调用 bootc switch
#   * 只写 /var/lib/armada-danyi-updates/<TAG>/，不删旧更新与其他资源，
#     不接触游戏与存档；真实 OCI 校验由 bootc 导入执行
#   * 不设置也不覆写 HOME / CODEX_HOME
set -euo pipefail

CACHE_ROOT=/var/lib/armada-danyi-updates
REPO_SLUG=mydanyi/armada-danyi-build
API_LATEST="https://api.github.com/repos/${REPO_SLUG}/releases/latest"
DOWNLOAD_BASE="https://github.com/${REPO_SLUG}/releases/download"

die()  { printf 'update: 错误: %s\n' "$*" >&2; exit 1; }
info() { printf 'update: %s\n' "$*"; }

# ----------------------------------------------------------- 运行环境检查

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  die "需要 root 权限，请使用 sudo 运行"
fi

ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || die "本脚本只支持 aarch64，当前架构: $ARCH"

command -v bootc >/dev/null 2>&1 || die "未找到 bootc 命令"
bootc status >/dev/null 2>&1 || die "bootc status 执行失败，当前系统不是 bootc 主机"

for cmd in curl jq sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
done

# ----------------------------------------------------------- 解析 tag

[ "$#" -le 1 ] || die "用法: $0 [release-tag]"

if [ "$#" -eq 1 ] && [ -n "$1" ]; then
  TAG=$1
  info "使用指定 tag: $TAG"
else
  info "查询 GitHub 最新 release ..."
  TAG=$(curl -fsSL --retry 3 "$API_LATEST" | jq -r '.tag_name // empty') \
    || die "查询 GitHub API 失败"
  [ -n "$TAG" ] || die "GitHub API 未返回 tag_name"
  info "最新 tag: $TAG"
fi

# tag 安全校验：字母数字开头；其余只允许字母数字点横线下划线（无斜杠、无空白）
case $TAG in
  [A-Za-z0-9]*) : ;;
  *) die "非法 tag（必须以字母数字开头）: '$TAG'" ;;
esac
case $TAG in
  *[!A-Za-z0-9._-]*) die "非法 tag（只允许字母数字点横线下划线，禁止斜杠与空白）: '$TAG'" ;;
esac

# ----------------------------------------------------------- 缓存目录

CACHE=$CACHE_ROOT/$TAG
mkdir -p "$CACHE" || die "无法创建缓存目录: $CACHE"
info "缓存目录: $CACHE"

SUMS_FILE=$CACHE/SHA256SUMS
PARTS_RAW=$CACHE/.oci-parts.raw
PARTS_SORTED=$CACHE/.oci-parts.sorted

# ----------------------------------------------------------- 下载 SHA256SUMS

info "下载 SHA256SUMS ..."
curl -fsSL --retry 3 -o "$SUMS_FILE" "$DOWNLOAD_BASE/$TAG/SHA256SUMS" \
  || die "下载 SHA256SUMS 失败"
[ -s "$SUMS_FILE" ] || die "SHA256SUMS 为空"

# ----------------------------------------------------------- 严格解析 SHA256SUMS

OCI_NAME=
OCI_HASH=
oci_count=0
part_count=0
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
    [[ $h =~ ^[0-9a-fA-F]{64}$ ]] || die "SHA256SUMS 中 '$n' 的哈希不是 64 位十六进制"
    oci_count=$((oci_count + 1))
    [ "$oci_count" -eq 1 ] || die "SHA256SUMS 含多个 OCI 完整包（'$OCI_NAME' 与 '$n'），拒绝"
    OCI_NAME=$n
    OCI_HASH=$h
  elif [[ $n =~ ^armada-[A-Za-z0-9._-]+\.oci\.tar\.part[0-9]{3,}$ ]]; then
    [[ $h =~ ^[0-9a-fA-F]{64}$ ]] || die "SHA256SUMS 中 '$n' 的哈希不是 64 位十六进制"
    printf '%s %s %s\n' "${n##*part}" "$n" "$h" >> "$PARTS_RAW"
    part_count=$((part_count + 1))
  fi
done < "$SUMS_FILE"

[ "$oci_count" -eq 1 ] || die "SHA256SUMS 中必须恰好有 1 个 armada-*.oci.tar 完整包，实际 $oci_count 个"
[ "$part_count" -gt 0 ] || die "SHA256SUMS 中没有分卷条目"
info "完整包: $OCI_NAME"

# 只保留属于该完整包的分卷，并按 part 编号排序（防跨包分卷与伪造文件名）
: > "$PARTS_SORTED"
while read -r num name hash; do
  case $name in
    "$OCI_NAME".part[0-9][0-9][0-9]*)
      printf '%s %s %s\n' "$num" "$name" "$hash" >> "$PARTS_SORTED"
      ;;
  esac
done < "$PARTS_RAW"

[ -s "$PARTS_SORTED" ] || die "SHA256SUMS 中没有属于 $OCI_NAME 的分卷"

sort -k1,1n -k2,2 "$PARTS_SORTED" > "$PARTS_SORTED.tmp"
mv -f "$PARTS_SORTED.tmp" "$PARTS_SORTED"

EXPECTED=0
while read -r num name hash; do
  idx=$((10#$num))
  [ "$idx" -eq "$EXPECTED" ] \
    || die "分卷编号不连续（期望 $EXPECTED，实际 $num），可能缺卷或已被篡改"
  EXPECTED=$((EXPECTED + 1))
done < "$PARTS_SORTED"
TOTAL_PARTS=$EXPECTED
info "分卷数量: $TOTAL_PARTS"

# ----------------------------------------------------------- 逐卷下载并校验

while read -r num name hash; do
  info "下载分卷 $name"
  curl -fsSL --retry 3 -o "$CACHE/$name" "$DOWNLOAD_BASE/$TAG/$name" \
    || die "下载分卷失败: $name"
  printf '%s  %s\n' "$hash" "$name" > "$CACHE/.part-check"
  ( cd "$CACHE" && sha256sum -c "$CACHE/.part-check" > /dev/null ) \
    || die "分卷校验失败（内容被篡改或传输损坏）: $name"
done < "$PARTS_SORTED"
rm -f "$CACHE/.part-check"

# ----------------------------------------------------------- 合并与完整校验

PENDING=$CACHE/$OCI_NAME.pending
info "合并分卷 -> $OCI_NAME.pending"
: > "$PENDING"
while read -r num name hash; do
  cat -- "$CACHE/$name" >> "$PENDING"
done < "$PARTS_SORTED"

ACTUAL=$(sha256sum "$PENDING" | cut -d' ' -f1)
if [ "$ACTUAL" != "$OCI_HASH" ]; then
  rm -f -- "$PENDING"
  die "完整 OCI 校验失败（缺卷或内容被篡改），未执行 bootc switch"
fi
mv -f -- "$PENDING" "$CACHE/$OCI_NAME"
info "OCI 归档校验通过: $CACHE/$OCI_NAME"

# ----------------------------------------------------------- bootc switch

info "调用 bootc switch（不 --apply、不重启）"
bootc switch --transport oci-archive "$CACHE/$OCI_NAME" || die "bootc switch 失败"

printf '\n更新已准备完成，请手动重启；可用 sudo bootc status 查看\n'
