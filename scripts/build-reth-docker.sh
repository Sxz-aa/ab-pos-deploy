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
readonly context_dir="${build_dir}/.reth-runtime-context"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 \
    || fail "Docker Engine is required"

docker buildx version >/dev/null 2>&1 \
    || fail "Docker Buildx is required"

[[ -x "${artifact}" ]] \
    || fail "Reth binary artifact not found: ${artifact}; run make reth first"

rm -rf -- "${context_dir}"
mkdir -p "${context_dir}"

function cleanup() {
    rm -rf -- "${context_dir}"
}

trap cleanup EXIT

install -m 0755 "${artifact}" "${context_dir}/reth"

printf 'Building AB Reth Docker image %s:%s for %s\n' \
    "${reth_image}" "${ab_reth_version}" "${reth_platform}"

docker buildx build \
    --platform "${reth_platform}" \
    --load \
    --build-arg "AB_RETH_VERSION=${ab_reth_version}" \
    -t "${reth_image}:${ab_reth_version}" \
    -f "${root_dir}/docker/reth/Runtime.Dockerfile" \
    "${context_dir}"

printf 'Created Docker image %s:%s\n' \
    "${reth_image}" "${ab_reth_version}"
