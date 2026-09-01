#!/usr/bin/env bash

set -euo pipefail

# Generate AB PoS genesis validator keys and deposit data.
# The withdrawal address is the only required input.

readonly validator_count="${VALIDATOR_COUNT:-1000}"
readonly validator_start_index=0
readonly deposit_amount=2048
readonly root_path="${ABPOS_ROOT_PATH:-/data/abpos}"
readonly keys_path="${root_path}/keys"
readonly validator_keys_path="${keys_path}/validator_keys"
readonly legacy_validator_keys_path="${validator_keys_path}/validator_keys"
readonly password_path="${keys_path}/pwd.txt"
readonly mnemonic_path="${keys_path}/mnemonic.txt"
readonly host_uid="${SUDO_UID:-$(id -u)}"
readonly host_gid="${SUDO_GID:-$(id -g)}"
readonly deposit_cli_image="${DEPOSIT_CLI_IMAGE:-ghcr.io/ethstaker/ethstaker-deposit-cli:latest}"

readonly devnet_chain_setting='{"network_name":"abcore","genesis_fork_version":"0x000001ab","exit_fork_version":"0x000001ab","genesis_validator_root":"0x0000000000000000000000000000000000000000000000000000000000000000","multiplier":1,"min_activation_amount":32,"min_deposit_amount":1}'

function color() {
    # Usage: color "31;5" "message"
    # Foreground colors: 31 red, 32 green, 33 yellow, 34 blue, 36 cyan, 37 white.
    printf '\033[%sm%s\033[0m\n' "$@"
}

function fail() {
    color "31" "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<'USAGE'
Generate AB PoS genesis validator keys and deposit data.

Usage:
  generate-abpos-validators.sh [OPTIONS] <withdrawal-address>
  WITHDRAWAL_ADDRESS=<address> generate-abpos-validators.sh [OPTIONS]

Arguments:
  withdrawal-address
      Ethereum execution-layer address that receives validator withdrawals.
      The value must be a 20-byte hexadecimal address prefixed with 0x.

Options:
  -h, --help
      Show this help message and exit.

Environment variables:
  WITHDRAWAL_ADDRESS
      Withdrawal address used when the positional argument is omitted.

  VALIDATOR_COUNT
      Number of validators to generate.
      Default: 1000

  ABPOS_ROOT_PATH
      Root output directory.
      Default: /data/abpos

  DEPOSIT_CLI_IMAGE
      Deposit CLI Docker image.
      Default: ghcr.io/ethstaker/ethstaker-deposit-cli:latest

Outputs:
  <ABPOS_ROOT_PATH>/keys/validator_keys/keystore-*.json
  <ABPOS_ROOT_PATH>/keys/validator_keys/deposit_data-*.json
  <ABPOS_ROOT_PATH>/keys/mnemonic.txt
  <ABPOS_ROOT_PATH>/keys/pwd.txt

Examples:
  ./generate-abpos-validators.sh \
    0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332

  VALIDATOR_COUNT=10 \
    ABPOS_ROOT_PATH=/data/abpos/test-10 \
    ./generate-abpos-validators.sh \
    0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332

  WITHDRAWAL_ADDRESS=0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332 \
    ./generate-abpos-validators.sh

Security:
  Share only deposit_data-*.json with the Network Operator.
  Never share mnemonic.txt, pwd.txt, or validator keystores.
USAGE
}

function require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        fail "Required command not found: $1"
}

function count_files() {
    local directory="$1"
    local pattern="$2"

    find "${directory}" \
        -maxdepth 1 \
        -type f \
        -name "${pattern}" \
        -print |
        wc -l |
        tr -d ' '
}

function normalize_legacy_output() {
    local legacy_file_count
    local destination_file_count
    local remaining_entry

    if [[ ! -d "${legacy_validator_keys_path}" ]]; then
        return
    fi

    legacy_file_count="$(
        find "${legacy_validator_keys_path}" \
            -maxdepth 1 \
            -type f \
            -print |
            wc -l |
            tr -d ' '
    )"

    if [[ "${legacy_file_count}" -eq 0 ]]; then
        rmdir "${legacy_validator_keys_path}" 2>/dev/null || true
        return
    fi

    destination_file_count="$(
        find "${validator_keys_path}" \
            -maxdepth 1 \
            -type f \
            -print |
            wc -l |
            tr -d ' '
    )"

    if [[ "${destination_file_count}" -ne 0 ]]; then
        fail \
            "Both the legacy and current validator key directories contain files."
    fi

    color "33" \
        "Legacy nested validator key directory detected."

    color "33" \
        "Moving generated files to ${validator_keys_path}..."

    find "${legacy_validator_keys_path}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type f \
        -exec mv -t "${validator_keys_path}" -- {} +

    remaining_entry="$(
        find "${legacy_validator_keys_path}" \
            -mindepth 1 \
            -maxdepth 1 \
            -print \
            -quit
    )"

    if [[ -n "${remaining_entry}" ]]; then
        fail \
            "Unexpected entries remain in ${legacy_validator_keys_path}."
    fi

    rmdir "${legacy_validator_keys_path}"

    color "32" \
        "Legacy validator key directory normalized successfully."
}

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage >&2
        fail "Unknown option: $1"
        ;;
esac

if [[ "$#" -gt 1 ]]; then
    usage >&2
    fail "Expected one withdrawal address, received $# arguments."
fi

withdrawal_address="${1:-${WITHDRAWAL_ADDRESS:-}}"

if [[ -z "${withdrawal_address}" ]]; then
    usage
    fail "Withdrawal address is required."
fi

if [[ ! "${withdrawal_address}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    fail "Invalid withdrawal address: ${withdrawal_address}"
fi

if [[ ! "${validator_count}" =~ ^[1-9][0-9]*$ ]]; then
    fail "VALIDATOR_COUNT must be a positive integer."
fi

require_command docker
require_command find
require_command mv
require_command openssl
require_command rmdir

if ! docker info >/dev/null 2>&1; then
    fail \
        "Docker is unavailable or the current user does not have permission to access it."
fi

umask 077

if ! mkdir -p "${validator_keys_path}"; then
    fail "Cannot create ${validator_keys_path}. Check the directory permissions."
fi

if [[ ! -w "${keys_path}" ]]; then
    fail "The current user cannot write to ${keys_path}."
fi

chmod 700 "${keys_path}" "${validator_keys_path}"

normalize_legacy_output

existing_file_count="$(
    find "${validator_keys_path}" \
        -maxdepth 1 \
        -type f \
        -print |
        wc -l |
        tr -d ' '
)"

keystore_count="$(
    count_files \
        "${validator_keys_path}" \
        'keystore-*.json'
)"

deposit_file_count="$(
    count_files \
        "${validator_keys_path}" \
        'deposit_data-*.json'
)"

if [[ "${existing_file_count}" -eq 0 ]]; then
    color "34" \
        "Generating validator secrets and ${validator_count} validator keys..."

    if [[ ! -s "${password_path}" ]]; then
        openssl rand -hex 32 >"${password_path}"
        chmod 600 "${password_path}"

        color "32" \
            "Generated keystore password: ${password_path}"
    else
        if [[ ! -r "${password_path}" ]]; then
            fail \
                "Keystore password file is not readable: ${password_path}"
        fi

        color "33" \
            "Using existing keystore password: ${password_path}"
    fi

    if [[ ! -s "${mnemonic_path}" ]]; then
        docker run --rm \
            --tty \
            --env TERM=xterm \
            --user "${host_uid}:${host_gid}" \
            -v "${keys_path}:/app/keys" \
            "${deposit_cli_image}" \
            --non_interactive \
            --ignore_connectivity \
            --language english \
            generate-mnemonic \
            --mnemonic_language=english \
            --output_file=/app/keys/mnemonic.txt

        chmod 600 "${mnemonic_path}"

        color "32" \
            "Generated mnemonic: ${mnemonic_path}"
    else
        if [[ ! -r "${mnemonic_path}" ]]; then
            fail \
                "Mnemonic file is not readable: ${mnemonic_path}"
        fi

        color "33" \
            "Using existing mnemonic: ${mnemonic_path}"
    fi

    mnemonic="$(<"${mnemonic_path}")"
    keystore_password="$(<"${password_path}")"

    docker run --rm \
        --tty \
        --env TERM=xterm \
        --user "${host_uid}:${host_gid}" \
        -v "${validator_keys_path}:/app/validator_keys" \
        "${deposit_cli_image}" \
        --non_interactive \
        --ignore_connectivity \
        --language english \
        existing-mnemonic \
        --mnemonic="${mnemonic}" \
        --keystore_password="${keystore_password}" \
        --validator_start_index="${validator_start_index}" \
        --num_validators="${validator_count}" \
        --withdrawal_address="${withdrawal_address}" \
        --compounding \
        --amount="${deposit_amount}" \
        --devnet_chain_setting="${devnet_chain_setting}" \
        --folder=/app

    unset mnemonic
    unset keystore_password

    keystore_count="$(
        count_files \
            "${validator_keys_path}" \
            'keystore-*.json'
    )"

    deposit_file_count="$(
        count_files \
            "${validator_keys_path}" \
            'deposit_data-*.json'
    )"

    if [[ "${keystore_count}" -ne "${validator_count}" ]]; then
        fail \
            "Expected ${validator_count} keystores, found ${keystore_count}."
    fi

    if [[ "${deposit_file_count}" -ne 1 ]]; then
        fail \
            "Expected exactly one deposit data file, found ${deposit_file_count}."
    fi
elif [[
    "${keystore_count}" -eq "${validator_count}" &&
    "${deposit_file_count}" -eq 1
]]; then
    if [[ ! -s "${password_path}" ]]; then
        fail \
            "Existing validator keys found, but ${password_path} is missing."
    fi

    if [[ ! -r "${password_path}" ]]; then
        fail \
            "Existing validator keys found, but ${password_path} is not readable."
    fi

    if [[ ! -s "${mnemonic_path}" ]]; then
        fail \
            "Existing validator keys found, but ${mnemonic_path} is missing."
    fi

    if [[ ! -r "${mnemonic_path}" ]]; then
        fail \
            "Existing validator keys found, but ${mnemonic_path} is not readable."
    fi

    color "33" \
        "Existing complete validator key set found; skipping key generation."
else
    fail \
        "The validator key directory contains an inconsistent key set. Expected ${validator_count} keystores and one deposit data file; found ${keystore_count} keystores and ${deposit_file_count} deposit data files."
fi

mapfile -t deposit_files < <(
    find "${validator_keys_path}" \
        -maxdepth 1 \
        -type f \
        -name 'deposit_data-*.json' \
        -print |
        sort
)

if [[ "${#deposit_files[@]}" -ne 1 ]]; then
    fail \
        "Expected exactly one deposit data file, found ${#deposit_files[@]}."
fi

readonly deposit_file="${deposit_files[0]}"

chmod 644 "${deposit_file}"

color "32" "Validator generation completed successfully."
color "37" "Withdrawal address: ${withdrawal_address}"
color "37" "Validator count: ${validator_count}"
color "37" "Validator keys: ${validator_keys_path}"
color "37" "Mnemonic backup: ${mnemonic_path}"
color "37" "Keystore password: ${password_path}"
color "32" "Genesis deposit data: ${deposit_file}"
color "33" \
    "Share only the deposit data JSON with operations staff."
