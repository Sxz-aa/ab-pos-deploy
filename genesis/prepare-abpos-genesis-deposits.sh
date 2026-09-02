#!/usr/bin/env bash

set -euo pipefail

# Validate EthStaker deposit data from multiple Genesis Validator Operators and
# convert it to the additional-validator format consumed by
# eth-genesis-state-generator.

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly default_deposits_dir="${script_dir}/validator-deposits"
readonly default_output_file="${script_dir}/additional-validators.txt"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

function usage() {
    cat <<'USAGE'
Usage:
  ./prepare-abpos-genesis-deposits.sh [DEPOSITS_DIR] [OUTPUT_FILE]

Environment variables:
  EXPECTED_VALIDATOR_COUNT   Approved record count; checked when provided
  GENESIS_FORK_VERSION       Expected fork version (default: 0x000001ab)
  DEPOSIT_NETWORK_NAME       Expected Deposit CLI network name (default: abcore)
  MIN_VALIDATOR_GWEI         Minimum accepted amount (default: 32000000000)
  MAX_VALIDATOR_GWEI         Maximum accepted amount (default: 2048000000000)

DEPOSITS_DIR is searched recursively for deposit_data-*.json files.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
[[ "$#" -le 2 ]] || { usage >&2; exit 2; }

readonly deposits_dir="${1:-${default_deposits_dir}}"
readonly output_file="${2:-${default_output_file}}"
readonly expected_count="${EXPECTED_VALIDATOR_COUNT:-}"
readonly expected_fork_version="${GENESIS_FORK_VERSION:-0x000001ab}"
readonly expected_network_name="${DEPOSIT_NETWORK_NAME:-abcore}"
readonly min_validator_gwei="${MIN_VALIDATOR_GWEI:-32000000000}"
readonly max_validator_gwei="${MAX_VALIDATOR_GWEI:-2048000000000}"

command -v jq >/dev/null 2>&1 || fail "Required command not found: jq"
[[ -d "${deposits_dir}" ]] || fail "Deposit directory not found: ${deposits_dir}"
[[ -z "${expected_count}" || "${expected_count}" =~ ^[1-9][0-9]*$ ]] \
    || fail "EXPECTED_VALIDATOR_COUNT must be a positive integer."
[[ "${expected_fork_version}" =~ ^(0x)?[0-9a-fA-F]{8}$ ]] \
    || fail "GENESIS_FORK_VERSION must contain exactly four bytes."
[[ -n "${expected_network_name}" ]] || fail "DEPOSIT_NETWORK_NAME must not be empty."
[[ "${min_validator_gwei}" =~ ^[0-9]+$ && "${max_validator_gwei}" =~ ^[0-9]+$ ]] \
    || fail "Validator amount limits must be non-negative integers."
(( min_validator_gwei <= max_validator_gwei )) \
    || fail "MIN_VALIDATOR_GWEI must not exceed MAX_VALIDATOR_GWEI."

mapfile -t deposit_files < <(
    find "${deposits_dir}" -type f -name 'deposit_data-*.json' -print | sort
)
(( ${#deposit_files[@]} > 0 )) \
    || fail "No deposit_data-*.json files found under ${deposits_dir}."

temporary_output="$(mktemp)"
temporary_pubkeys="$(mktemp)"
function cleanup() {
    rm -f -- "${temporary_output}" "${temporary_pubkeys}"
}
trap cleanup EXIT

total_records=0
total_staked_gwei=0
expected_fork_clean="${expected_fork_version#0x}"

for deposit_file in "${deposit_files[@]}"; do
    jq -e 'type == "array" and length > 0' "${deposit_file}" >/dev/null \
        || fail "Deposit file must be a non-empty JSON array: ${deposit_file}"

    while IFS=$'\t' read -r pubkey withdrawal_credentials amount fork_version network_name; do
        pubkey="${pubkey#0x}"
        withdrawal_credentials="${withdrawal_credentials#0x}"
        fork_version="${fork_version#0x}"

        [[ "${pubkey}" =~ ^[0-9a-fA-F]{96}$ ]] \
            || fail "Invalid validator pubkey in ${deposit_file}: ${pubkey}"
        [[ "${withdrawal_credentials}" =~ ^[0-9a-fA-F]{64}$ ]] \
            || fail "Invalid withdrawal credentials in ${deposit_file} for ${pubkey}."
        [[ "${amount}" =~ ^[0-9]+$ ]] \
            || fail "Invalid deposit amount in ${deposit_file} for ${pubkey}: ${amount}"
        (( amount >= min_validator_gwei && amount <= max_validator_gwei )) \
            || fail "Deposit amount is outside the accepted range for ${pubkey}: ${amount}"
        [[ "${fork_version,,}" == "${expected_fork_clean,,}" ]] \
            || fail "Fork version mismatch for ${pubkey}: expected ${expected_fork_version}, got ${fork_version}"
        [[ "${network_name}" == "${expected_network_name}" ]] \
            || fail "Network name mismatch for ${pubkey}: expected ${expected_network_name}, got ${network_name}"

        normalized_pubkey="0x${pubkey,,}"
        printf '%s\n' "${normalized_pubkey}" >> "${temporary_pubkeys}"
        printf '%s:0x%s:%s\n' \
            "${normalized_pubkey}" "${withdrawal_credentials,,}" "${amount}" \
            >> "${temporary_output}"
        total_staked_gwei=$((total_staked_gwei + amount))
        total_records=$((total_records + 1))
    done < <(
        jq -r '.[] | [
            (.pubkey // ""),
            (.withdrawal_credentials // ""),
            ((.amount // "") | tostring),
            (.fork_version // ""),
            (.network_name // "")
        ] | @tsv' "${deposit_file}"
    )
done

unique_records="$(sort -u "${temporary_pubkeys}" | wc -l | tr -d ' ')"
(( total_records == unique_records )) || fail "Duplicate validator pubkey detected."
[[ -z "${expected_count}" || "${total_records}" -eq "${expected_count}" ]] \
    || fail "Validator count mismatch: expected ${expected_count}, found ${total_records}."

mkdir -p "$(dirname "${output_file}")"
install -m 600 "${temporary_output}" "${output_file}"

printf 'Validated deposit files: %s\n' "${#deposit_files[@]}"
printf 'Validated validators: %s\n' "${total_records}"
printf 'Total stake (Gwei): %s\n' "${total_staked_gwei}"
printf 'Created %s\n' "${output_file}"
