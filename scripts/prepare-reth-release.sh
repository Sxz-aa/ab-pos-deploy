#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly reth_version="${RETH_VERSION:-v2.5.2}"
readonly ab_reth_version="${AB_RETH_VERSION:-${reth_version}-ab.1}"
readonly reth_image="${RETH_IMAGE:-ghcr.io/abdaodev/ab-reth}"
readonly image_ref="${reth_image}:${ab_reth_version}"
readonly reth_platform="${RETH_PLATFORM:-linux/amd64}"
manifest_error=""

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "${reth_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "RETH_VERSION must be an upstream vMAJOR.MINOR.PATCH version; got: ${reth_version}"
[[ "${ab_reth_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ab\.[1-9][0-9]*$ \
    && "${ab_reth_version%-ab.*}" == "${reth_version}" ]] \
    || fail "AB_RETH_VERSION must match ${reth_version}-ab.N; got: ${ab_reth_version}"

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required"
docker info >/dev/null 2>&1 || fail "Docker is unavailable or permission was denied"

manifest_error="$(mktemp)"
trap 'rm -f -- "${manifest_error}"' EXIT

if docker manifest inspect "${image_ref}" >/dev/null 2>"${manifest_error}"; then
    printf 'Reusing published image %s\n' "${image_ref}"
    docker pull --platform "${reth_platform}" "${image_ref}"

    published_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image_ref}")"
    [[ "${published_version}" == "${ab_reth_version}" ]] \
        || fail "published image version label is ${published_version:-empty}; expected ${ab_reth_version}"

    "${root_dir}/scripts/export-reth-image.sh"
    exit 0
fi

if ! grep -Eiq 'manifest unknown|no such manifest' "${manifest_error}"; then
    printf 'ERROR: unable to determine whether %s exists:\n' "${image_ref}" >&2
    sed 's/^/  /' "${manifest_error}" >&2
    exit 1
fi

printf 'Published image %s does not exist; building it once.\n' "${image_ref}"
make -C "${root_dir}" reth reth-docker
docker push "${image_ref}"
"${root_dir}/scripts/export-reth-image.sh"
