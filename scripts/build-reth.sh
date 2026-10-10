#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly source_dir="${build_dir}/src/reth"

readonly reth_version="${RETH_VERSION:-v2.5.2}"
readonly ab_reth_version="${AB_RETH_VERSION:-${reth_version}-ab.1}"
readonly reth_platform="${RETH_PLATFORM:-linux/amd64}"
readonly platform_arch="${reth_platform#*/}"

readonly artifact_name="ab-reth-${ab_reth_version}-linux-${platform_arch}"
readonly artifact="${build_dir}/${artifact_name}"
readonly export_dir="${build_dir}/.reth-binary-export"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 \
    || fail "Docker Engine is required to build ab-reth"

command -v sha256sum >/dev/null 2>&1 \
    || fail "sha256sum is required"

docker buildx version >/dev/null 2>&1 \
    || fail "Docker Buildx is required to build ab-reth; install docker-buildx (Ubuntu) or docker-buildx-plugin (Docker CE)."

[[ "${reth_platform}" == linux/amd64 || "${reth_platform}" == linux/arm64 ]] \
    || fail "RETH_PLATFORM must be linux/amd64 or linux/arm64"

[[ "${reth_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "RETH_VERSION must be an upstream vMAJOR.MINOR.PATCH version"

[[ "${ab_reth_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ab\.[1-9][0-9]*$ \
    && "${ab_reth_version%-ab.*}" == "${reth_version}" ]] \
    || fail "AB_RETH_VERSION must match ${reth_version}-ab.N"

"${root_dir}/scripts/prepare-reth-source.sh"

rm -rf -- "${export_dir}"
mkdir -p "${export_dir}"

function cleanup() {
    rm -rf -- "${export_dir}"
}

trap cleanup EXIT

printf 'Building ab-reth %s for %s\n' \
    "${ab_reth_version}" "${reth_platform}"

docker buildx build \
    --platform "${reth_platform}" \
    --target binary \
    --output "type=local,dest=${export_dir}" \
    -f "${root_dir}/docker/reth/Dockerfile" \
    "${source_dir}"

[[ -x "${export_dir}/reth" ]] \
    || fail "Docker build did not export the Reth binary"

install -m 0755 \
    "${export_dir}/reth" \
    "${artifact}"

(
    cd "${build_dir}"
    sha256sum "${artifact_name}" > "${artifact_name}.sha256"
)

printf 'Created %s\n' "${artifact}"
printf 'Created %s.sha256\n' "${artifact}"
