#!/usr/bin/env bash
# package-release.sh — 生成 armada 发布目录（分卷 + SHA256SUMS + update.sh + 源码归档）
#
# 用法:
#   package-release.sh TASK_ROOT SRC_ROOT
#
# 必需环境变量:
#   ARMADA_VERSION              版本号；只允许字母、数字、点、横线、下划线
# 可选环境变量:
#   ARMADA_RELEASE_PART_BYTES   单个分卷字节数；默认 1992294400 (1900MiB)，
#                               只能调小（测试用），不允许大于默认值
#
# 输入（必须存在）:
#   TASK_ROOT/output/armada-<VER>.img.gz
#   TASK_ROOT/output/armada-<VER>.oci.tar
#   SRC_ROOT/personal-build/update.sh
#
# 产出（全部写在 TASK_ROOT/output/ 之内）:
#   TASK_ROOT/output/release/armada-<VER>.img.gz.7z.001 ...（安装包，由 package-install.sh 生成）
#   TASK_ROOT/output/release/armada-<VER>.oci.tar.part000 ...
#   TASK_ROOT/output/release/update.sh
#   TASK_ROOT/output/release/source.tar.gz        （有 fixture 或是 git checkout 时）
#   TASK_ROOT/output/release/SHA256SUMS
#
# 构建先在 OUTPUT 下的临时 staging 目录内完成，全部成功后整体 mv 成 release/；
# 任何失败只清理自己创建的 staging，绝不修改输入，也不覆盖已存在的 release/。
set -euo pipefail

die()  { printf 'package-release: 错误: %s\n' "$*" >&2; exit 1; }
info() { printf 'package-release: %s\n' "$*"; }

DEFAULT_PART_BYTES=1992294400   # 1900 MiB

# ------------------------------------------------------------------ 参数校验

[ "$#" -eq 2 ] || die "用法: $0 TASK_ROOT SRC_ROOT"
TASK_ROOT=$1
SRC_ROOT=$2

[ -n "${ARMADA_VERSION:-}" ] || die "必须设置环境变量 ARMADA_VERSION"
case $ARMADA_VERSION in
  *[!A-Za-z0-9._-]*)
    die "ARMADA_VERSION 只能包含字母数字点横线下划线: '$ARMADA_VERSION'"
    ;;
esac

PART_BYTES=${ARMADA_RELEASE_PART_BYTES:-$DEFAULT_PART_BYTES}
case $PART_BYTES in
  ''|*[!0-9]*) die "ARMADA_RELEASE_PART_BYTES 必须是正整数: '$PART_BYTES'" ;;
esac
PART_BYTES=$((10#$PART_BYTES))
[ "$PART_BYTES" -gt 0 ] || die "ARMADA_RELEASE_PART_BYTES 必须为正整数"
[ "$PART_BYTES" -le "$DEFAULT_PART_BYTES" ] \
  || die "ARMADA_RELEASE_PART_BYTES 不能大于默认值 $DEFAULT_PART_BYTES"

for c in split sha256sum mktemp; do
  command -v "$c" >/dev/null 2>&1 || die "缺少依赖命令: $c"
done

# ------------------------------------------------------------------ 输入检查

OUTPUT=$TASK_ROOT/output
IMG_GZ=$OUTPUT/armada-$ARMADA_VERSION.img.gz
OCI_TAR=$OUTPUT/armada-$ARMADA_VERSION.oci.tar
SOURCE_UPDATE=$SRC_ROOT/personal-build/update.sh
RELEASE_DIR=$OUTPUT/release

IMG_NAME=$(basename "$IMG_GZ")
OCI_NAME=$(basename "$OCI_TAR")

[ -d "$OUTPUT" ]        || die "输出目录不存在: $OUTPUT"
[ -f "$IMG_GZ" ]        || die "缺少输入文件: $IMG_GZ"
[ -f "$OCI_TAR" ]       || die "缺少输入文件: $OCI_TAR"
[ -f "$SOURCE_UPDATE" ] || die "缺少升级脚本: $SOURCE_UPDATE"
if [ -e "$RELEASE_DIR" ] || [ -L "$RELEASE_DIR" ]; then
  die "发布目录已存在，拒绝覆盖: $RELEASE_DIR"
fi

info "版本: $ARMADA_VERSION"
info "分卷大小: $PART_BYTES 字节"

# ------------------------------------------------------------------ staging

STAGING=
cleanup() {
  if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
    info "清理临时目录: $STAGING"
    rm -rf -- "$STAGING"
  fi
}
trap cleanup EXIT

STAGING=$(mktemp -d "$OUTPUT/.release-staging.XXXXXX")
info "临时目录: $STAGING"

# ------------------------------------------------------ 安装包分卷（7z，经 helper）

# 安装镜像不再按字节 split：交给同目录的 package-install.sh，它把完整的
# .img.gz 原样（不 gunzip、不产生巨大 raw 副本）封装成多卷
# armada-<VER>.img.gz.7z.001…，并在自己的输出目录写一份清单（.img.gz 与每个
# 分卷的 SHA256）。该 helper 需要 gzip（仅校验输入）与 7zz；发布步骤在
# release-tools 镜像内运行，因此二者都可直接使用。
INSTALL_HELPER="$(dirname -- "${BASH_SOURCE[0]}")/package-install.sh"
[ -f "$INSTALL_HELPER" ] || die "缺少安装包 helper: $INSTALL_HELPER"

INSTALL_DIR=$STAGING/install
info "生成安装包 7z 分卷: $INSTALL_HELPER"
bash "$INSTALL_HELPER" "$IMG_GZ" "$INSTALL_DIR" "$PART_BYTES"

count_volumes() {               # count_volumes <目录>
  local n=0 p
  for p in "$1"/*.7z.[0-9][0-9][0-9]; do
    if [ -f "$p" ]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

VOLUMES=$(count_volumes "$INSTALL_DIR")
[ "$VOLUMES" -gt 0 ] || die "helper 未能生成 $IMG_NAME 的 7z 分卷"

# 仅把 helper 产出的 .7z 分卷搬到 STAGING；helper 的清单稍后并入父 SHA256SUMS。
for v in "$INSTALL_DIR"/*.7z.[0-9][0-9][0-9]; do
  [ -f "$v" ] || continue
  mv -- "$v" "$STAGING/"
done
info "安装包 7z 分卷 ${VOLUMES} 个"

# ------------------------------------------------------------------ OCI 分卷

count_parts() {                 # count_parts <前缀>
  local n=0 p
  for p in "$1"[0-9][0-9][0-9]; do
    if [ -f "$p" ]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}

info "分卷 $OCI_NAME"
split -b "$PART_BYTES" -d -a 3 "$OCI_TAR" "$STAGING/$OCI_NAME.part"

OCI_PARTS=$(count_parts "$STAGING/$OCI_NAME.part")
[ "$OCI_PARTS" -gt 0 ] || die "未能生成 $OCI_NAME 的分卷"
info "OCI 分卷 ${OCI_PARTS} 个"

# ------------------------------------------------------------------ SHA256SUMS

SUMS=$STAGING/SHA256SUMS
: > "$SUMS"

sha_of() { sha256sum "$1" | cut -d' ' -f1; }
record() {
  local digest
  digest=$(sha_of "$1") || die "计算 SHA256 失败: $1"
  printf '%s  %s\n' "$digest" "$2" >> "$SUMS"
}

# 完整输入：OCI 整包。安装包的 .img.gz 由 helper 清单提供（见下），此处不再重复
# 记录，避免对同一份 .img.gz 重复哈希、重复条目。
record "$OCI_TAR" "$OCI_NAME"

# OCI 分卷（安装包分卷由 helper 清单提供，见下）
for p in "$STAGING/$OCI_NAME.part"[0-9][0-9][0-9]; do
  [ -f "$p" ] || continue
  record "$p" "$(basename "$p")"
done

# 并入 helper 清单：完整 .img.gz 与全部 .img.gz.7z 分卷的 SHA256 已由 helper 算好，
# 直接追加，避免对同一份镜像与同一批分卷重复哈希；清单中不含 raw.img。
# 分卷 basename 已与 STAGING 一致。
[ -f "$INSTALL_DIR/SHA256SUMS" ] || die "helper 未生成清单: $INSTALL_DIR/SHA256SUMS"
cat -- "$INSTALL_DIR/SHA256SUMS" >> "$SUMS"

# 仅清理 helper 自己留下的清单与（搬空后的）子目录，不触碰其它文件。
rm -f -- "$INSTALL_DIR/SHA256SUMS"
rmdir -- "$INSTALL_DIR" 2>/dev/null \
  || die "helper 输出目录存在未预期的残留: $INSTALL_DIR"

# update.sh
info "复制 update.sh"
cp -- "$SOURCE_UPDATE" "$STAGING/update.sh"
chmod 755 "$STAGING/update.sh"
record "$STAGING/update.sh" "update.sh"

# 源码归档：优先使用测试 fixture，其次从 git checkout 生成，都没有则跳过
ARCHIVE_FIXTURE=${ARMADA_SOURCE_ARCHIVE:-$SRC_ROOT/source.tar.gz}
if [ -f "$ARCHIVE_FIXTURE" ]; then
  info "复制源码 fixture: $ARCHIVE_FIXTURE"
  cp -- "$ARCHIVE_FIXTURE" "$STAGING/source.tar.gz"
  record "$STAGING/source.tar.gz" "source.tar.gz"
elif [ -e "$SRC_ROOT/.git" ] && command -v git >/dev/null 2>&1; then
  info "从 git checkout 生成源码归档 (git archive HEAD | gzip -1)"
  git -C "$SRC_ROOT" archive HEAD | gzip -1 > "$STAGING/source.tar.gz"
  record "$STAGING/source.tar.gz" "source.tar.gz"
else
  info "跳过源码归档（无 fixture，且 SRC_ROOT 不是 git checkout）"
fi

[ -s "$SUMS" ] || die "SHA256SUMS 为空，构建失败"

# ------------------------------------------------------------------ 发布

if [ -e "$RELEASE_DIR" ] || [ -L "$RELEASE_DIR" ]; then
  die "发布目录已存在，拒绝覆盖: $RELEASE_DIR"
fi

mv -- "$STAGING" "$RELEASE_DIR"
STAGING=

info "发布目录已生成: $RELEASE_DIR"
info "SHA256SUMS 共 $(wc -l < "$RELEASE_DIR/SHA256SUMS") 行"
