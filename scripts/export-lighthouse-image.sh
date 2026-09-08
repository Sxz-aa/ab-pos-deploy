#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly lighthouse_version="${LIGHTHOUSE_VERSION:-v8.2.2}"
readonly ab_lighthouse_version="${AB_LIGHTHOUSE_VERSION:-${lighthouse_version}-ab.1}"
readonly lighthouse_image="${LIGHTHOUSE_IMAGE_REPOSITORY:-ghcr.io/abdaodev/ab-lighthouse}"
readonly lighthouse_platform="${LIGHTHOUSE_PLATFORM:-linux/amd64}"
readonly platform_arch="${lighthouse_platform#*/}"
readonly artifact_name="ab-lighthouse-${ab_lighthouse_version}-linux-${platform_arch}"
readonly artifact="${build_dir}/${artifact_name}"
readonly image_ref="${lighthouse_image}:${ab_lighthouse_version}"
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

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required to export the ab-lighthouse image"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

docker image inspect "${image_ref}" >/dev/null 2>&1 || fail "image is not available locally: ${image_ref}"

published_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image_ref}")"
[[ "${published_version}" == "${ab_lighthouse_version}" ]] \
    || fail "image version label is ${published_version:-empty}; expected ${ab_lighthouse_version}"

published_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${image_ref}")"
[[ "${published_platform}" == "${lighthouse_platform}" ]] \
    || fail "image platform is ${published_platform}; expected ${lighthouse_platform}"

mkdir -p "${build_dir}"
container_id="$(docker create --platform "${lighthouse_platform}" "${image_ref}")"
docker cp "${container_id}:/usr/local/bin/lighthouse" "${artifact}"
chmod 0755 "${artifact}"
touch "${artifact}"

(
    cd "${build_dir}"
    sha256sum "${artifact_name}" > "${artifact_name}.sha256"
)

printf 'Exported %s from %s\n' "${artifact}" "${image_ref}"
printf 'Created %s.sha256\n' "${artifact}"
