#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly geth_repository="${GETH_REPOSITORY:-https://github.com/ethereum/go-ethereum.git}"
readonly geth_version="${GETH_VERSION:-v1.17.5}"
readonly geth_platform="${GETH_PLATFORM:-linux/amd64}"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

shopt -s nullglob
patches=("${root_dir}"/patches/go-ethereum/*.patch)
(( ${#patches[@]} > 0 )) || fail "no Geth patches found under ${root_dir}/patches/go-ethereum"

inputs=(
    "${root_dir}/docker/geth/Dockerfile"
    "${root_dir}/docker/geth/Runtime.Dockerfile"
    "${root_dir}/scripts/prepare-geth-source.sh"
    "${root_dir}/scripts/build-geth.sh"
    "${root_dir}/scripts/build-geth-docker.sh"
    "${patches[@]}"
)

for input in "${inputs[@]}"; do
    [[ -f "${input}" ]] || fail "build input is missing: ${input}"
done

{
    printf 'repository=%s\n' "${geth_repository}"
    printf 'version=%s\n' "${geth_version}"
    printf 'platform=%s\n' "${geth_platform}"
    for input in "${inputs[@]}"; do
        printf 'path=%s\n' "${input#"${root_dir}/"}"
        sha256sum "${input}" | awk '{print $1}'
    done
} | sha256sum | awk '{print $1}'
