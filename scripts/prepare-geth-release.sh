#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly geth_version="${GETH_VERSION:-v1.17.5}"
readonly ab_geth_version="${AB_GETH_VERSION:-${geth_version}-ab.1}"
readonly geth_image="${GETH_IMAGE:-ghcr.io/abdaodev/ab-geth}"
readonly image_ref="${geth_image}:${ab_geth_version}"
manifest_error=""

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "${geth_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "GETH_VERSION must be an upstream vMAJOR.MINOR.PATCH tag; got: ${geth_version}"
[[ "${ab_geth_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ab\.[1-9][0-9]*$ \
    && "${ab_geth_version%-ab.*}" == "${geth_version}" ]] \
    || fail "AB_GETH_VERSION must match ${geth_version}-ab.N; got: ${ab_geth_version}"

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required"
docker info >/dev/null 2>&1 || fail "Docker is unavailable or permission was denied"

manifest_error="$(mktemp)"
trap 'rm -f -- "${manifest_error}"' EXIT

if docker manifest inspect "${image_ref}" >/dev/null 2>"${manifest_error}"; then
    printf 'Reusing published image %s\n' "${image_ref}"
    docker pull "${image_ref}"
    published_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image_ref}")"
    [[ "${published_version}" == "${ab_geth_version}" ]] \
        || fail "published image version label is ${published_version:-empty}; expected ${ab_geth_version}"

    "${root_dir}/scripts/export-geth-image.sh"
    exit 0
fi

if ! grep -Eiq 'manifest unknown|no such manifest' "${manifest_error}"; then
    printf 'ERROR: unable to determine whether %s exists:\n' "${image_ref}" >&2
    sed 's/^/  /' "${manifest_error}" >&2
    exit 1
fi

printf 'Published image %s does not exist; building it once.\n' "${image_ref}"
make -C "${root_dir}" geth geth-docker
docker push "${image_ref}"
