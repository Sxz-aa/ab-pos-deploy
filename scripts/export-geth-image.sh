#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly geth_version="${GETH_VERSION:-v1.17.5}"
readonly ab_geth_version="${AB_GETH_VERSION:-${geth_version}-ab.1}"
readonly geth_image="${GETH_IMAGE:-ghcr.io/abdaodev/ab-geth}"
readonly geth_platform="${GETH_PLATFORM:-linux/amd64}"
readonly platform_arch="${geth_platform#*/}"
readonly artifact_name="ab-geth-${ab_geth_version}-linux-${platform_arch}"
readonly artifact="${build_dir}/${artifact_name}"
readonly archive_name="${artifact_name}.docker.tar.gz"
readonly archive="${build_dir}/${archive_name}"
readonly image_ref="${geth_image}:${ab_geth_version}"
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

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required to export the ab-geth image"
command -v gzip >/dev/null 2>&1 || fail "gzip is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

docker image inspect "${image_ref}" >/dev/null 2>&1 || fail "image is not available locally: ${image_ref}"

published_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image_ref}")"
[[ "${published_version}" == "${ab_geth_version}" ]] \
    || fail "image version label is ${published_version:-empty}; expected ${ab_geth_version}"

mkdir -p "${build_dir}"
container_id="$(docker create "${image_ref}")"
docker cp "${container_id}:/usr/local/bin/geth" "${artifact}"
chmod 0755 "${artifact}"
touch "${artifact}"

(
    cd "${build_dir}"
    sha256sum "${artifact_name}" > "${artifact_name}.sha256"
)

image_id="$(docker image inspect --format '{{.Id}}' "${image_ref}")"
image_digest="$(docker image inspect --format '{{join .RepoDigests ","}}' "${image_ref}")"
build_fingerprint="$(docker image inspect --format '{{index .Config.Labels "io.abfoundation.ab-geth.build-fingerprint"}}' "${image_ref}")"
{
    printf 'artifact=%s\n' "${artifact_name}"
    printf 'ab_geth_version=%s\n' "${ab_geth_version}"
    printf 'upstream_version=%s\n' "${geth_version}"
    printf 'platform=%s\n' "${geth_platform}"
    printf 'source_image=%s\n' "${image_ref}"
    printf 'image_id=%s\n' "${image_id}"
    printf 'image_digest=%s\n' "${image_digest}"
    printf 'build_fingerprint=%s\n' "${build_fingerprint}"
    printf 'reused_image=true\n'
} > "${artifact}.build-info.txt"

docker save "${image_ref}" | gzip -n > "${archive}"
(
    cd "${build_dir}"
    sha256sum "${archive_name}" > "${archive_name}.sha256"
)

printf 'Exported %s from %s\n' "${artifact}" "${image_ref}"
printf 'Created %s.sha256\n' "${artifact}"
printf 'Created %s.build-info.txt\n' "${artifact}"
printf 'Created %s\n' "${archive}"
printf 'Created %s.sha256\n' "${archive}"
