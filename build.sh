#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly build_dir="${BUILD_DIR:-${root_dir}/build}"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

function usage() {
    cat <<'USAGE'
Usage:
  ./build.sh --check NETWORK RELEASE_PHASE
  ./build.sh VERSION NETWORK RELEASE_PHASE

RELEASE_PHASE must be genesis or post-genesis.
USAGE
}

function effective_lines() {
    sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "$1"
}

function require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

function validate_line_file() {
    local path="$1"
    local label="$2"
    local pattern="$3"
    local line

    [[ -f "${path}" ]] || return 0
    while IFS= read -r line; do
        [[ "${line}" =~ ${pattern} ]] || fail "invalid ${label} entry in ${path}: ${line}"
    done < <(effective_lines "${path}")
}

function validate_network() {
    local target_network="$1"
    local target_phase="$2"
    local target_share_dir="${root_dir}/abpos/${target_network}/share"
    local required_file
    local jwt

    [[ "${target_network}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid network name: ${target_network}"
    case "${target_phase}" in
        genesis|post-genesis) ;;
        *) fail "RELEASE_PHASE must be genesis or post-genesis; got: ${target_phase}" ;;
    esac

    [[ -d "${target_share_dir}" ]] || fail "network share directory not found: ${target_share_dir}"
    for required_file in genesis.json genesis.ssz jwtsecret config.yaml config.prysm.yaml; do
        [[ -s "${target_share_dir}/${required_file}" ]] || fail "required network file is missing or empty: ${target_share_dir}/${required_file}"
    done

    require_command jq
    jq -e 'type == "object" and (.config.chainId | type == "number")' \
        "${target_share_dir}/genesis.json" >/dev/null \
        || fail "genesis.json is invalid or config.chainId is not numeric"

    jwt="$(tr -d '[:space:]' < "${target_share_dir}/jwtsecret")"
    [[ "${jwt}" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] \
        || fail "jwtsecret must contain exactly 32 bytes encoded as 64 hexadecimal characters, optionally prefixed by 0x"

    validate_line_file "${target_share_dir}/bootstrap_nodes.txt" "beacon bootstrap node" '^enr:[^[:space:]]+$'
    validate_line_file "${target_share_dir}/enodes.txt" "Geth enode" '^enode://[^[:space:]]+$'
    validate_line_file "${target_share_dir}/checkpoint_sync_urls.txt" "checkpoint URL" '^https?://[^[:space:]]+$'

    for required_file in deploy_block.txt deposit_contract_block.txt; do
        if [[ -f "${target_share_dir}/${required_file}" ]]; then
            [[ "$(tr -d '[:space:]' < "${target_share_dir}/${required_file}")" =~ ^[0-9]+$ ]] \
                || fail "${required_file} must contain one non-negative block number"
        fi
    done

    if [[ "${target_phase}" == "post-genesis" ]]; then
        [[ -s "${target_share_dir}/checkpoint_sync_urls.txt" ]] \
            || fail "post-genesis releases require checkpoint_sync_urls.txt"
        [[ -n "$(effective_lines "${target_share_dir}/checkpoint_sync_urls.txt")" ]] \
            || fail "checkpoint_sync_urls.txt has no usable checkpoint URL"
    elif [[ ! -s "${target_share_dir}/checkpoint_sync_urls.txt" ]]; then
        printf '%s\n' \
            "INFO: checkpoint_sync_urls.txt is absent. This is valid for a genesis release;" \
            "      non-genesis nodes must use --checkpoint-url until a post-genesis release is published."
    fi

    printf 'Validated %s network files for the %s release phase.\n' "${target_network}" "${target_phase}"
}

if [[ "${1:-}" == "--check" ]]; then
    [[ "$#" -eq 3 ]] || { usage >&2; exit 2; }
    validate_network "$2" "$3"
    exit 0
fi

[[ "$#" -eq 3 ]] || { usage >&2; exit 2; }
readonly version="$1"
readonly network="$2"
readonly release_phase="$3"
readonly share_dir="${root_dir}/abpos/${network}/share"
readonly artifact="${build_dir}/abpos-${network}-${version}.tar.gz"

[[ "${version}" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "invalid VERSION: ${version}"
validate_network "${network}" "${release_phase}"
require_command tar
require_command sha256sum

mkdir -p "${build_dir}"
tar -C "${share_dir}" -czf "${artifact}" .
(
    cd "${build_dir}"
    sha256sum "$(basename "${artifact}")" > "$(basename "${artifact}").sha256"
)

printf 'Created %s\n' "${artifact}"
printf 'Created %s.sha256\n' "${artifact}"
