#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly reth_version="${RETH_VERSION:-v2.5.2}"
readonly ab_reth_version="${AB_RETH_VERSION:-${reth_version}-ab.1}"
readonly reth_image="${RETH_IMAGE:-ghcr.io/abdaodev/ab-reth}"
readonly reth_platform="${RETH_PLATFORM:-linux/amd64}"
readonly platform_arch="${reth_platform#*/}"
readonly artifact_name="ab-reth-${ab_reth_version}-linux-${platform_arch}"
readonly artifact="${build_dir}/${artifact_name}"
readonly image_ref="${reth_image}:${ab_reth_version}"
container_id=""

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

function cleanup() {
    if [[ -n "${container_id}" ]]; then
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required to export the ab-reth image"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

docker image inspect "${image_ref}" >/dev/null 2>&1 || fail "image is not available locally: ${image_ref}"

published_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image_ref}")"
[[ "${published_version}" == "${ab_reth_version}" ]] \
    || fail "image version label is ${published_version:-empty}; expected ${ab_reth_version}"

published_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${image_ref}")"
[[ "${published_platform}" == "${reth_platform}" ]] \
    || fail "image platform is ${published_platform}; expected ${reth_platform}"

mkdir -p "${build_dir}"
container_id="$(docker create --platform "${reth_platform}" "${image_ref}")"
docker cp "${container_id}:/usr/local/bin/reth" "${artifact}"
chmod 0755 "${artifact}"
touch "${artifact}"

(
    cd "${build_dir}"
    sha256sum "${artifact_name}" > "${artifact_name}.sha256"
)

printf 'Exported %s from %s\n' "${artifact}" "${image_ref}"
printf 'Created %s.sha256\n' "${artifact}"
