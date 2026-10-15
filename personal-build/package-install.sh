#!/usr/bin/env bash
#
# package-install.sh -- wrap a release .img.gz into split 7z volumes + SHA256SUMS.
#
#   package-install.sh INPUT_IMG_GZ OUTPUT_DIR PART_BYTES
#
# The .img.gz is stored verbatim (no gunzip, no giant raw copy) inside a
# multi-volume 7z archive. Everything is staged in a private mktemp dir under the
# output parent, verified by fully extracting the produced first volume and
# comparing its SHA256 with the complete source .img.gz, and only then renamed
# into place. Any failure aborts with no published output. The input is never
# modified. No network, devices, or reboot.
#
set -euo pipefail

readonly MAX_PART_BYTES=1992294400   # hard ceiling for a -v volume size

die() { printf 'package-install: %s\n' "$*" >&2; exit 1; }

# ---- arguments -------------------------------------------------------------
[ "$#" -eq 3 ] || die "usage: package-install.sh INPUT_IMG_GZ OUTPUT_DIR PART_BYTES"
input=$1
outdir=$2
part=$3

case $input  in /*) ;; *) die "input path must be absolute: $input"  ;; esac
case $outdir in /*) ;; *) die "output path must be absolute: $outdir" ;; esac

# ---- validate input artefact ----------------------------------------------
[ -f "$input" ] || die "input is not a regular file: $input"
[ -s "$input" ] || die "input is empty: $input"
inbase=${input##*/}
case $inbase in
  *.img.gz) ;;
  *) die "input basename must end in .img.gz: $inbase" ;;
esac
indir=$(dirname -- "$input")
[ -d "$indir" ] || die "input parent is not a directory: $indir"

# gzip -t streams the whole file and fails on any corruption; it only reads the
# input and never rewrites it.
gzip -t -- "$input" || die "input is not a valid gzip file: $input"

# ---- validate output target ------------------------------------------------
# Refuse anything already present, including a dangling symlink.
if [ -e "$outdir" ] || [ -L "$outdir" ]; then
  die "output already exists: $outdir"
fi
outparent=$(dirname -- "$outdir")
[ -d "$outparent" ] || die "output parent is not a directory: $outparent"

# ---- validate volume size --------------------------------------------------
case $part in
  ''|*[!0-9]*) die "PART_BYTES must be a positive decimal integer: $part" ;;
esac
[ "$part" -gt 0 ]                || die "PART_BYTES must be greater than zero"
[ "$part" -le "$MAX_PART_BYTES" ] || die "PART_BYTES exceeds $MAX_PART_BYTES"

# ---- private staging area --------------------------------------------------
# Owned by this run; the trap removes only this directory.
stage=$(mktemp -d "$outparent/.package-install.XXXXXX") \
  || die "cannot create staging dir under $outparent"
trap 'rm -rf -- "$stage"' EXIT

pub=$stage/out     # final output tree, renamed into place on success
mkdir -p -- "$pub"

# ---- hash the source .img.gz exactly once ----------------------------------
srcsum=$(sha256sum -- "$input")   # a hashing failure aborts here (set -e)
srcsum=${srcsum%% *}             # keep the digest only

# ---- store into split 7z volumes -------------------------------------------
# Run from the input file's directory and add the basename only (no abs path),
# so the archive holds armada-<VER>.img.gz verbatim (-mx=0 stores it as-is).
archive=$pub/$inbase.7z
( cd -- "$indir" && \
  7zz a "$archive" "$inbase" -t7z -mx=0 -mmt=8 -ms=off -v"${part}b" )

first=$archive.001
[ -f "$first" ] || die "expected first volume not produced: $first"

# ---- verify: extract the first volume (joins parts), compare the digest -----
# pipefail makes a corrupt or partial extraction fail the pipeline.
extracted=$(7zz x -so "$first" | sha256sum)
extracted=${extracted%% *}
[ "$extracted" = "$srcsum" ] || die "extracted archive hash mismatch"

# ---- manifest: source .img.gz digest + every volume digest -----------------
# No raw.img entry: the archive only ever contains the .img.gz. Volumes are
# hashed here on the server, before publish -- no NAS readback.
{
  printf '%s  %s\n' "$srcsum" "$inbase"
  for vol in "$pub"/"$inbase".7z.*; do
    vsum=$(sha256sum -- "$vol"); vsum=${vsum%% *}
    printf '%s  %s\n' "$vsum" "${vol##*/}"
  done
} > "$pub/SHA256SUMS"

# ---- publish atomically ----------------------------------------------------
mv -T -- "$pub" "$outdir"
