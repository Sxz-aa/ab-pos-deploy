#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly source_dir="${build_dir}/src/lighthouse"
readonly lighthouse_version="${LIGHTHOUSE_VERSION:-v8.2.2}"
readonly ab_lighthouse_version="${AB_LIGHTHOUSE_VERSION:-${lighthouse_version}-ab.1}"
readonly lighthouse_platform="${LIGHTHOUSE_PLATFORM:-linux/amd64}"
readonly platform_arch="${lighthouse_platform#*/}"
readonly artifact_name="ab-lighthouse-${ab_lighthouse_version}-linux-${platform_arch}"
readonly artifact="${build_dir}/${artifact_name}"
readonly export_dir="${build_dir}/.lighthouse-binary-export"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required to build ab-lighthouse"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
docker buildx version >/dev/null 2>&1 || fail "Docker Buildx is required to build ab-lighthouse; install docker-buildx (Ubuntu) or docker-buildx-plugin (Docker CE)."

[[ "${lighthouse_platform}" == linux/amd64 || "${lighthouse_platform}" == linux/arm64 ]] \
    || fail "LIGHTHOUSE_PLATFORM must be linux/amd64 or linux/arm64"
[[ "${ab_lighthouse_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ab\.[1-9][0-9]*$ \
    && "${ab_lighthouse_version%-ab.*}" == "${lighthouse_version}" ]] \
    || fail "AB_LIGHTHOUSE_VERSION must match ${lighthouse_version}-ab.N"

"${root_dir}/scripts/prepare-lighthouse-source.sh"
rm -rf -- "${export_dir}"
mkdir -p "${export_dir}"

function cleanup() {
    rm -rf -- "${export_dir}"
}
trap cleanup EXIT

printf 'Building ab-lighthouse %s for %s\n' "${ab_lighthouse_version}" "${lighthouse_platform}"
docker buildx build \
    --platform "${lighthouse_platform}" \
    --target binary \
    --output "type=local,dest=${export_dir}" \
    -f "${root_dir}/docker/lighthouse/Dockerfile" \
    "${source_dir}"

[[ -x "${export_dir}/lighthouse" ]] || fail "Docker build did not export the lighthouse binary"
install -m 0755 "${export_dir}/lighthouse" "${artifact}"
(
    cd "${build_dir}"
    sha256sum "${artifact_name}" > "${artifact_name}.sha256"
)

printf 'Created %s\n' "${artifact}"
printf 'Created %s.sha256\n' "${artifact}"
