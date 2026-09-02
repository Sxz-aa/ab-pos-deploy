#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"
readonly source_dir="${build_dir}/src/go-ethereum"
readonly geth_version="${GETH_VERSION:-v1.17.5}"
readonly ab_geth_version="${AB_GETH_VERSION:-${geth_version}-ab.1}"
readonly geth_platform="${GETH_PLATFORM:-linux/amd64}"
readonly platform_arch="${geth_platform#*/}"
readonly artifact_name="ab-geth-${ab_geth_version}-linux-${platform_arch}"
readonly artifact="${build_dir}/${artifact_name}"
readonly export_dir="${build_dir}/.geth-binary-export"
readonly temporary_image="ab-geth-build:${ab_geth_version}"
container_id=""

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker Engine is required to build ab-geth"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

"${root_dir}/scripts/prepare-geth-source.sh"
rm -rf -- "${export_dir}"
mkdir -p "${export_dir}"

function cleanup() {
    if [[ -n "${container_id}" ]]; then
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
    fi
    docker image rm "${temporary_image}" >/dev/null 2>&1 || true
    rm -rf -- "${export_dir}"
}
trap cleanup EXIT

printf 'Building ab-geth %s for %s\n' "${ab_geth_version}" "${geth_platform}"
if docker buildx version >/dev/null 2>&1; then
    docker buildx build \
        --platform "${geth_platform}" \
        --target binary \
        --output "type=local,dest=${export_dir}" \
        --build-arg "AB_GETH_VERSION=${ab_geth_version}" \
        -f "${root_dir}/docker/geth/Dockerfile" \
        "${source_dir}"
else
    printf 'Docker buildx is unavailable; using the classic Docker builder.\n'
    DOCKER_BUILDKIT=0 docker build \
        --platform "${geth_platform}" \
        --target runtime \
        --build-arg "AB_GETH_VERSION=${ab_geth_version}" \
        -t "${temporary_image}" \
        -f "${root_dir}/docker/geth/Dockerfile" \
        "${source_dir}"
    container_id="$(docker create "${temporary_image}")"
    docker cp "${container_id}:/usr/local/bin/geth" "${export_dir}/geth"
fi

[[ -x "${export_dir}/geth" ]] || fail "Docker build did not export the geth binary"
install -m 0755 "${export_dir}/geth" "${artifact}"
(
    cd "${build_dir}"
    sha256sum "${artifact_name}" > "${artifact_name}.sha256"
)

printf 'Created %s\n' "${artifact}"
printf 'Created %s.sha256\n' "${artifact}"
