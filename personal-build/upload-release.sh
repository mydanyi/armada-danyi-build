#!/usr/bin/env bash
# upload-release.sh -- upload every release asset of a draft GitHub Release.
#
# Usage:
#   upload-release.sh TASK_ROOT RELEASE_ID
#
# Uploads TASK_ROOT/output/release/* (all regular, non-empty files) to the
# draft Release RELEASE_ID, strictly sequentially, one file at a time. An
# exact-name asset that already matches RELEASE_DIR/SHA256SUMS is skipped;
# otherwise the previous asset is removed and the file is re-uploaded, retrying
# up to five times. The Release must be a draft first: a public Release is
# refused before any mutation.
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

# ----------------------------------------------- expected digests

expected_sha256() {  # expected_sha256 <file> -> lowercase 64-hex sha256, else nothing
  local file="$1" name manifest
  name="$(basename -- "${file}")"
  if [[ "${name}" == "SHA256SUMS" ]]; then
    # The manifest has no entry for itself; hash this small file directly.
    sha256sum -- "${file}" 2>/dev/null | awk '{print $1}'
    return
  fi
  manifest="${RELEASE_DIR}/SHA256SUMS"
  [[ -f "${manifest}" ]] || return 1
  awk -v n="${name}" '
    $1 ~ /^[0-9a-fA-F]{64}$/ {
      f = $2; sub(/^\*/, "", f)
      if (f == n) { print tolower($1); found = 1; exit }
    }
    END { if (!found) exit 1 }
  ' "${manifest}"
}

# ----------------------------------------------- one sequential attempt

upload_attempt() {  # upload_attempt <file> -> 0 ok, 1 retryable failure
  local file="$1" name size assets asset_id encoded resp
  local expected gh_state gh_size gh_digest
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
  gh_state="$(jq -r --arg n "${name}" 'map(select(.name == $n)) | .[0].state // empty' "${assets}")" \
    || return 1
  gh_size="$(jq -r --arg n "${name}" 'map(select(.name == $n)) | .[0].size // empty' "${assets}")" \
    || return 1
  gh_digest="$(jq -r --arg n "${name}" 'map(select(.name == $n)) | .[0].digest // empty' "${assets}")" \
    || return 1
  expected="$(expected_sha256 "${file}" || true)"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
    || die "no valid SHA256 for ${name} in ${RELEASE_DIR}/SHA256SUMS"

  # Resume: an exact-name asset whose state, size and content digest already
  # match the local file is complete and must not be re-uploaded.
  if [[ -n "${asset_id}" && "${gh_state}" == "uploaded" \
        && "${gh_size}" == "${size}" && "${gh_digest}" == "sha256:${expected}" ]]; then
    info "already uploaded ${name} (${size} bytes, checksum matches)"
    return 0
  fi

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

  jq -e --arg n "${name}" --argjson s "${size}" --arg d "sha256:${expected}" \
    '(.name == $n) and (.size == $s) and (.state == "uploaded") and (.digest == $d)' "${resp}" >/dev/null \
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
    if (( attempt >= 5 )); then
      die "failed to upload $(basename -- "${file}") after ${attempt} attempts"
    fi
    info "attempt ${attempt} failed for $(basename -- "${file}"); retry in 5s"
    sleep 5
    attempt=$((attempt + 1))
  done
done

info "all ${#ASSETS[@]} assets uploaded; release ${RELEASE_ID} left as draft"
