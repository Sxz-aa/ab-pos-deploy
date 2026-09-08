#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly lighthouse_version="${LIGHTHOUSE_VERSION:-v8.2.2}"
readonly ab_lighthouse_version="${AB_LIGHTHOUSE_VERSION:-${lighthouse_version}-ab.1}"
readonly lighthouse_image="${LIGHTHOUSE_IMAGE_REPOSITORY:-ghcr.io/abdaodev/ab-lighthouse}"
readonly lighthouse_platform="${LIGHTHOUSE_PLATFORM:-linux/amd64}"
readonly platform_arch="${lighthouse_platform#*/}"
readonly binary="${build_dir}/ab-lighthouse-${ab_lighthouse_version}-linux-${platform_arch}"
readonly context_dir="${build_dir}/.lighthouse-runtime-context"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required to build the ab-lighthouse image"
docker buildx version >/dev/null 2>&1 || fail "Docker Buildx is required to build the ab-lighthouse image; install docker-buildx (Ubuntu) or docker-buildx-plugin (Docker CE)."

[[ -x "${binary}" ]] || fail "patched lighthouse binary not found: ${binary}; run make lighthouse"
mkdir -p "${build_dir}"
rm -rf -- "${context_dir}"
mkdir -p "${context_dir}"
trap 'rm -rf -- "${context_dir}"' EXIT
install -m 0755 "${binary}" "${context_dir}/lighthouse"

printf 'Building Docker image %s:%s for %s\n' "${lighthouse_image}" "${ab_lighthouse_version}" "${lighthouse_platform}"
docker buildx build \
    --load \
    --platform "${lighthouse_platform}" \
    --build-arg "AB_LIGHTHOUSE_VERSION=${ab_lighthouse_version}" \
    -t "${lighthouse_image}:${ab_lighthouse_version}" \
    -f "${root_dir}/docker/lighthouse/Runtime.Dockerfile" \
    "${context_dir}"
