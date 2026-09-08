#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly geth_version="${GETH_VERSION:-v1.17.5}"
readonly ab_geth_version="${AB_GETH_VERSION:-${geth_version}-ab.1}"
readonly geth_image="${GETH_IMAGE:-ghcr.io/abdaodev/ab-geth}"
readonly geth_platform="${GETH_PLATFORM:-linux/amd64}"
readonly platform_arch="${geth_platform#*/}"
readonly binary="${build_dir}/ab-geth-${ab_geth_version}-linux-${platform_arch}"
readonly context_dir="${build_dir}/.geth-runtime-context"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required to build the ab-geth image"
docker buildx version >/dev/null 2>&1 || fail "Docker Buildx is required to build the ab-geth image"

[[ -x "${binary}" ]] || fail "patched geth binary not found: ${binary}; run make geth"
mkdir -p "${build_dir}"
rm -rf -- "${context_dir}"
mkdir -p "${context_dir}"
trap 'rm -rf -- "${context_dir}"' EXIT
install -m 0755 "${binary}" "${context_dir}/geth"

printf 'Building Docker image %s:%s for %s\n' "${geth_image}" "${ab_geth_version}" "${geth_platform}"
docker buildx build \
    --load \
    --platform "${geth_platform}" \
    --build-arg "AB_GETH_VERSION=${ab_geth_version}" \
    -t "${geth_image}:${ab_geth_version}" \
    -f "${root_dir}/docker/geth/Runtime.Dockerfile" \
    "${context_dir}"
