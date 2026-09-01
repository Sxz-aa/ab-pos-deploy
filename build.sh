#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

function validate_network_files() {
    local target_chain="$1"
    local target_network="$2"
    local share_dir="${script_dir}/${target_chain}/${target_network}/share"
    local file
    local required_files=(
        genesis.json
        genesis.ssz
        jwtsecret
        config.yaml
        config.prysm.yaml
    )

    [[ -d "${share_dir}" ]] || fail "Network share directory not found: ${share_dir}"

    for file in "${required_files[@]}"; do
        [[ -s "${share_dir}/${file}" ]] || fail "Missing required network file: ${share_dir}/${file}"
    done

    if [[ ! -s "${share_dir}/checkpoint_sync_urls.txt" ]]; then
        printf '%s\n' \
            "WARNING: checkpoint_sync_urls.txt is absent; this artifact is suitable for genesis startup, but the default post-genesis command will require --checkpoint-url."
    fi
}

if [[ "${1:-}" == "--check" ]]; then
    [[ "$#" -eq 3 ]] || fail "Usage: $0 --check <chain> <network>"
    validate_network_files "$2" "$3"
    exit 0
fi

[[ "$#" -eq 3 ]] || fail "Usage: $0 <version> <chain> <network>"

readonly version="$1"
readonly chain="$2"
readonly network="$3"
readonly build_dir="${script_dir}/build"
readonly archive_name="${chain}-${network}-${version}.tar.gz"
readonly archive_path="${build_dir}/${archive_name}"

[[ "${version}" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "Invalid version: ${version}"
[[ "${chain}" =~ ^[a-z0-9-]+$ ]] || fail "Invalid chain: ${chain}"
[[ "${network}" =~ ^[a-z0-9-]+$ ]] || fail "Invalid network: ${network}"

validate_network_files "${chain}" "${network}"
mkdir -p "${build_dir}"

printf 'Building %s %s network artifact, version %s...\n' \
    "${chain}" "${network}" "${version}"

tar -czf "${archive_path}" -C "${script_dir}" "${chain}/${network}"

(
    cd "${build_dir}"
    sha256sum "${archive_name}" >"${archive_name}.sha256"
    sha256sum --check "${archive_name}.sha256"
)

printf 'Built: %s\n' "${archive_path}"
printf 'Checksum: %s.sha256\n' "${archive_path}"
