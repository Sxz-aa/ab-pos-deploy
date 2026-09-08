#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly lighthouse_version="${LIGHTHOUSE_VERSION:-v8.2.2}"
readonly ab_lighthouse_version="${AB_LIGHTHOUSE_VERSION:-${lighthouse_version}-ab.1}"
readonly lighthouse_image="${LIGHTHOUSE_IMAGE_REPOSITORY:-ghcr.io/abdaodev/ab-lighthouse}"
readonly image_ref="${lighthouse_image}:${ab_lighthouse_version}"
readonly lighthouse_platform="${LIGHTHOUSE_PLATFORM:-linux/amd64}"
manifest_error=""

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "${lighthouse_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "LIGHTHOUSE_VERSION must be an upstream vMAJOR.MINOR.PATCH tag; got: ${lighthouse_version}"
[[ "${ab_lighthouse_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ab\.[1-9][0-9]*$ \
    && "${ab_lighthouse_version%-ab.*}" == "${lighthouse_version}" ]] \
    || fail "AB_LIGHTHOUSE_VERSION must match ${lighthouse_version}-ab.N; got: ${ab_lighthouse_version}"

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required"
docker info >/dev/null 2>&1 || fail "Docker is unavailable or permission was denied"

manifest_error="$(mktemp)"
trap 'rm -f -- "${manifest_error}"' EXIT

if docker manifest inspect "${image_ref}" >/dev/null 2>"${manifest_error}"; then
    printf 'Reusing published image %s\n' "${image_ref}"
    docker pull --platform "${lighthouse_platform}" "${image_ref}"
    published_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image_ref}")"
    [[ "${published_version}" == "${ab_lighthouse_version}" ]] \
        || fail "published image version label is ${published_version:-empty}; expected ${ab_lighthouse_version}"

    "${root_dir}/scripts/export-lighthouse-image.sh"
    exit 0
fi

if ! grep -Eiq 'manifest unknown|no such manifest' "${manifest_error}"; then
    printf 'ERROR: unable to determine whether %s exists:\n' "${image_ref}" >&2
    sed 's/^/  /' "${manifest_error}" >&2
    exit 1
fi

printf 'Published image %s does not exist; building it once.\n' "${image_ref}"
make -C "${root_dir}" lighthouse lighthouse-docker
docker push "${image_ref}"
