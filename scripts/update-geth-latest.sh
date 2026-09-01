#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly geth_version="${GETH_VERSION:-v1.17.5}"
readonly ab_geth_version="${AB_GETH_VERSION:-${geth_version}-ab.1}"
readonly geth_image="${GETH_IMAGE:-ghcr.io/abdaodev/ab-geth}"
readonly image_ref="${geth_image}:${ab_geth_version}"
readonly latest_ref="${geth_image}:latest"
manifest_error=""

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

function version_is_greater() {
    local candidate="$1"
    local current="$2"
    [[ "$(printf '%s\n%s\n' "${candidate}" "${current}" | sort -V | tail -n 1)" == "${candidate}" \
        && "${candidate}" != "${current}" ]]
}

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required"
[[ "${ab_geth_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ab\.[1-9][0-9]*$ ]] \
    || fail "AB_GETH_VERSION is invalid: ${ab_geth_version}"
docker image inspect "${image_ref}" >/dev/null 2>&1 || docker pull "${image_ref}"

manifest_error="$(mktemp)"
trap 'rm -f -- "${manifest_error}"' EXIT

if ! docker manifest inspect "${latest_ref}" >/dev/null 2>"${manifest_error}"; then
    if ! grep -Eiq 'manifest unknown|no such manifest' "${manifest_error}"; then
        printf 'ERROR: unable to determine whether %s exists:\n' "${latest_ref}" >&2
        sed 's/^/  /' "${manifest_error}" >&2
        exit 1
    fi
    printf 'Publishing initial %s from %s\n' "${latest_ref}" "${image_ref}"
    docker tag "${image_ref}" "${latest_ref}"
    docker push "${latest_ref}"
    exit 0
fi

docker pull "${latest_ref}"
current_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${latest_ref}")"
[[ "${current_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ab\.[1-9][0-9]*$ ]] \
    || fail "${latest_ref} has an invalid or missing version label: ${current_version:-empty}"

if [[ "${ab_geth_version}" == "${current_version}" ]]; then
    candidate_id="$(docker image inspect --format '{{.Id}}' "${image_ref}")"
    latest_id="$(docker image inspect --format '{{.Id}}' "${latest_ref}")"
    [[ "${candidate_id}" == "${latest_id}" ]] \
        || fail "${latest_ref} and ${image_ref} claim the same version but have different image IDs"
    printf '%s already points to %s\n' "${latest_ref}" "${ab_geth_version}"
elif version_is_greater "${ab_geth_version}" "${current_version}"; then
    printf 'Updating %s from %s to %s\n' "${latest_ref}" "${current_version}" "${ab_geth_version}"
    docker tag "${image_ref}" "${latest_ref}"
    docker push "${latest_ref}"
else
    printf 'Keeping %s at %s; candidate %s is older.\n' \
        "${latest_ref}" "${current_version}" "${ab_geth_version}"
fi
