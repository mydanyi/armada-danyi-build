#!/usr/bin/env bash
# upload-release.sh -- upload every release asset of a draft GitHub Release.
#
# Usage:
#   upload-release.sh TASK_ROOT RELEASE_ID
#
# Uploads TASK_ROOT/output/release/* (all regular, non-empty files) to the
# draft Release RELEASE_ID, one file at a time. Concurrency grows runner memory
# and makes the API close the connection mid-transfer ("other side closed"), so
# files are streamed strictly sequentially and each file may retry up to three
# times after removing its own partial previous asset. The Release is required
# to be a draft first: a public Release is refused before any mutation.
#
# Required environment:
#   GITHUB_TOKEN        token with contents:write (never printed, no set -x)
#   GITHUB_REPOSITORY   "owner/repo"
set -euo pipefail

die()  { printf 'upload-release: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'upload-release: %s\n' "$*"; }

[ "$#" -eq 2 ] || die "usage: $0 TASK_ROOT RELEASE_ID"
TASK_ROOT=$1
RELEASE_ID=$2

[[ "${TASK_ROOT}" == /* ]] || die "TASK_ROOT must be absolute: ${TASK_ROOT}"
[[ "${RELEASE_ID}" =~ ^[0-9]+$ ]] || die "RELEASE_ID must be numeric: ${RELEASE_ID}"
: "${GITHUB_TOKEN:?}" "${GITHUB_REPOSITORY:?}"

for c in curl jq stat; do
  command -v "$c" >/dev/null 2>&1 || die "missing dependency: $c"
done

RELEASE_DIR="${TASK_ROOT}/output/release"
WORK="${TASK_ROOT}/work"
API="https://api.github.com/repos/${GITHUB_REPOSITORY}"
UPLOADS="https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets"

mkdir -p "${WORK}"

# ----------------------------------------------- collect assets (sequential)

ASSETS=()
shopt -s nullglob
for f in "${RELEASE_DIR}"/*; do
  [[ -f "${f}" && -s "${f}" ]] || continue
  ASSETS+=("${f}")
done
shopt -u nullglob
(( ${#ASSETS[@]} > 0 )) || die "no release assets found in ${RELEASE_DIR}"
info "assets to upload: ${#ASSETS[@]}"

# ----------------------------------------------- require a draft release

DRAFT_JSON="${WORK}/upload-release-${RELEASE_ID}.json"
curl -fsS --http1.1 \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${API}/releases/${RELEASE_ID}" -o "${DRAFT_JSON}" \
  || die "failed to read release ${RELEASE_ID}"
jq -e '.draft == true' "${DRAFT_JSON}" >/dev/null \
  || die "release ${RELEASE_ID} is not a draft; refusing to upload"

# ----------------------------------------------- one sequential attempt

upload_attempt() {  # upload_attempt <file> -> 0 ok, 1 retryable failure
  local file="$1" name size assets asset_id encoded resp
  name="$(basename -- "${file}")"
  size="$(stat -c '%s' -- "${file}")"

  # Previous assets of this release, so an exact-name partial upload can be
  # deleted before retrying. Only the exact match is ever removed.
  assets="${WORK}/upload-assets-${RELEASE_ID}.json"
  curl -fsS --http1.1 \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/releases/${RELEASE_ID}/assets?per_page=100" -o "${assets}" \
    || return 1
  asset_id="$(jq -r --arg n "${name}" 'map(select(.name == $n)) | .[0].id // empty' "${assets}")" \
    || return 1
  if [[ -n "${asset_id}" ]]; then
    info "removing previous asset ${name} (id ${asset_id})"
    curl -fsS --http1.1 -X DELETE \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API}/releases/assets/${asset_id}" -o /dev/null \
      || return 1
  fi

  encoded="$(jq -rn --arg n "${name}" '$n | @uri')" || return 1
  resp="${WORK}/upload-response-${RELEASE_ID}.json"

  # --upload-file streams the file instead of buffering it all in memory.
  curl -fsS --http1.1 \
    --request POST \
    --upload-file "${file}" \
    -H "Content-Type: application/octet-stream" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Expect:" \
    "${UPLOADS}?name=${encoded}" -o "${resp}" \
    || return 1

  jq -e --arg n "${name}" --argjson s "${size}" \
    '(.name == $n) and (.size == $s) and (.state == "uploaded")' "${resp}" >/dev/null \
    || return 1

  info "uploaded ${name} (${size} bytes, state uploaded)"
  return 0
}

# ----------------------------------------------- upload each file in order

for file in "${ASSETS[@]}"; do
  attempt=1
  while :; do
    if upload_attempt "${file}"; then
      break
    fi
    if (( attempt >= 3 )); then
      die "failed to upload $(basename -- "${file}") after ${attempt} attempts"
    fi
    info "attempt ${attempt} failed for $(basename -- "${file}"); retry in 5s"
    sleep 5
    attempt=$((attempt + 1))
  done
done

info "all ${#ASSETS[@]} assets uploaded; release ${RELEASE_ID} left as draft"
