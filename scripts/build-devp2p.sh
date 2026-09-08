#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly source_dir="${build_dir}/src/go-ethereum"
readonly geth_version="${GETH_VERSION:-v1.17.5}"
readonly geth_platform="${GETH_PLATFORM:-linux/amd64}"
readonly platform_arch="${geth_platform#*/}"
readonly artifact="${build_dir}/devp2p-${geth_version}-linux-${platform_arch}"
readonly export_dir="${build_dir}/.devp2p-binary-export"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required to build devp2p"
docker buildx version >/dev/null 2>&1 || fail "Docker Buildx is required to build devp2p"

"${root_dir}/scripts/prepare-geth-source.sh"
rm -rf -- "${export_dir}"
mkdir -p "${export_dir}"

function cleanup() {
    rm -rf -- "${export_dir}"
}
trap cleanup EXIT

printf 'Building devp2p %s for %s\n' "${geth_version}" "${geth_platform}"
docker buildx build \
    --platform "${geth_platform}" \
    --target binary \
    --output "type=local,dest=${export_dir}" \
    -f "${root_dir}/docker/geth/Devp2p.Dockerfile" \
    "${source_dir}"

[[ -x "${export_dir}/devp2p" ]] || fail "Docker build did not export the devp2p binary"
install -m 0755 "${export_dir}/devp2p" "${artifact}"
printf 'Created %s\n' "${artifact}"
