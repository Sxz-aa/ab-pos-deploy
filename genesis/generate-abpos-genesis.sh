#!/usr/bin/env bash

set -euo pipefail

# Build an AB PoS execution genesis and consensus genesis state from public
# deposit data or one local mnemonic. This script intentionally does not handle
# validator keystores, node deployment, bootnode discovery, or JWT secrets.

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly gwei_per_token=1000000000
readonly max_exact_integer=9007199254740991

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

function require_safe_positive_integer() {
    local label="$1"
    local value="$2"

    [[ "${value}" =~ ^[1-9][0-9]*$ ]] \
        || fail "${label} must be a positive integer."
    [[ "${#value}" -lt 16 \
        || ( "${#value}" -eq 16 && "${value}" < "9007199254740992" ) ]] \
        || fail "${label} is too large."
}

parsed_gwei=""
function parse_whole_token_amount_to_gwei() {
    local label="$1"
    local value="$2"

    [[ "${value}" =~ ^[1-9][0-9]*$ ]] \
        || fail "${label} must be a positive whole-token amount."
    [[ "${#value}" -lt 7 \
        || ( "${#value}" -eq 7 && "${value}" < "9007200" ) ]] \
        || fail "${label} is too large."
    parsed_gwei=$((value * gwei_per_token))
}

function usage() {
    cat <<'USAGE'
Usage:
  ./generate-abpos-genesis.sh [--config CONFIG_DIR] --prepare-deposit-settings
  ./generate-abpos-genesis.sh [--config CONFIG_DIR] [--deposit-data]
  ./generate-abpos-genesis.sh [--config CONFIG_DIR] --mnemonic MNEMONIC_FILE

Modes:
  prepare-deposit-settings
             Write CONFIG_DIR/deposit-settings.json for Genesis Validator
             Operators without building genesis.
  deposit-data  Build the validator set from all deposit_data-*.json files
                under CONFIG_DIR/validator-deposits. This is the default mode.
  mnemonic   Build the validator set from one local BIP-39 mnemonic file.
             --legacy is accepted as an alias.

Default configuration:
  CONFIG_DIR                 ./config, relative to this script
  Output                     CONFIG_DIR/genesis-output

Optional environment variables:
  GENESIS_CONFIG_DIR         Same as --config
  GENESIS_GENERATOR_IMAGE    Generator image (default: ethpandaops/ethereum-genesis-generator:6.1.6)
  EXPECTED_VALIDATOR_COUNT   Override NUMBER_OF_VALIDATORS from values.env
  GENESIS_TIMESTAMP          Override GENESIS_TIMESTAMP from values.env

For a production build, pin GENESIS_GENERATOR_IMAGE to a reviewed immutable
image digest and independently review every generated file before publication.
USAGE
}

genesis_mode="deposit-data"
prepare_deposit_settings=false
config_dir="${GENESIS_CONFIG_DIR:-${script_dir}/config}"
mnemonic_file=""
while (( "$#" > 0 )); do
    case "$1" in
        --config)
            [[ "$#" -ge 2 ]] || fail "--config requires a directory."
            config_dir="$2"
            shift 2
            ;;
        --deposit-data)
            genesis_mode="deposit-data"
            shift
            ;;
        --prepare-deposit-settings)
            prepare_deposit_settings=true
            shift
            ;;
        --mnemonic|--legacy)
            [[ "$#" -ge 2 ]] || fail "$1 requires a mnemonic file."
            genesis_mode="mnemonic"
            mnemonic_file="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -d "${config_dir}" ]] \
    || fail "Genesis config not found: ${config_dir}. Copy genesis/config-template to genesis/config first."
config_dir="$(cd "${config_dir}" && pwd)"
deposits_dir="${config_dir}/validator-deposits"
output_dir="${config_dir}/genesis-output"

if [[ "${prepare_deposit_settings}" == false ]]; then
    if [[ "${genesis_mode}" == "deposit-data" ]]; then
        [[ -d "${deposits_dir}" ]] \
            || fail "Deposit directory not found: ${deposits_dir}"
    else
        [[ -f "${mnemonic_file}" && -s "${mnemonic_file}" ]] \
            || fail "Mnemonic file not found or empty: ${mnemonic_file}"
        mnemonic_file="$(cd "$(dirname "${mnemonic_file}")" && pwd)/$(basename "${mnemonic_file}")"
    fi
fi

readonly genesis_mode prepare_deposit_settings config_dir deposits_dir mnemonic_file output_dir
readonly requested_validator_count="${EXPECTED_VALIDATOR_COUNT:-}"
readonly requested_genesis_timestamp="${GENESIS_TIMESTAMP:-}"
readonly generator_image="${GENESIS_GENERATOR_IMAGE:-ethpandaops/ethereum-genesis-generator:6.1.6}"
readonly requested_target_total_supply="${TARGET_TOTAL_SUPPLY:-}"
readonly requested_deposit_amount_multiplier="${DEPOSIT_AMOUNT_MULTIPLIER:-}"
readonly requested_deposit_amount_divisor="${DEPOSIT_AMOUNT_DIVISOR:-}"
readonly requested_min_deposit_amount="${MIN_DEPOSIT_AMOUNT:-}"
readonly requested_premine_address="${EL_PREMINE_ADDRESS:-}"
readonly requested_base_fee_per_gas="${EL_BASE_FEE_PER_GAS:-}"
readonly requested_config_name="${GENESIS_CONFIG_NAME:-}"
readonly requested_chain_name="${CHAIN_NAME:-}"
readonly requested_network_name="${NETWORK_NAME:-}"
readonly requested_min_validator_gwei="${MIN_VALIDATOR_GWEI:-}"
readonly requested_max_validator_gwei="${MAX_VALIDATOR_GWEI:-}"

required_commands=(jq awk)
if [[ "${prepare_deposit_settings}" == false ]]; then
    required_commands+=(docker sort diff)
fi
for command_name in "${required_commands[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "Required command not found: ${command_name}"
done

for required_file in values.env el/genesis-config.yaml cl/config.yaml cl/mnemonics.yaml; do
    [[ -s "${config_dir}/${required_file}" ]] \
        || fail "Required genesis source file is missing: ${config_dir}/${required_file}"
done

# Load the reviewed workspace settings. Per-run calculated values are appended
# only to a temporary copy and never modify the operator's values.env.
set -a
# shellcheck disable=SC1091
source "${config_dir}/values.env"
set +a

readonly expected_validator_count="${requested_validator_count:-${NUMBER_OF_VALIDATORS:-}}"
configured_genesis_timestamp="${requested_genesis_timestamp:-${GENESIS_TIMESTAMP:-0}}"
if [[ "${configured_genesis_timestamp}" == "0" ]]; then
    configured_genesis_timestamp="$(( $(date +%s) + 300 ))"
fi
readonly genesis_timestamp="${configured_genesis_timestamp}"
readonly chain_name="${requested_chain_name:-${CHAIN_NAME:-abcore}}"
readonly network_name="${requested_network_name:-${NETWORK_NAME:-testnet}}"
readonly expected_deposit_network_name="${chain_name}"
readonly min_validator_gwei="${requested_min_validator_gwei:-${MIN_VALIDATOR_GWEI:-32000000000}}"
readonly max_validator_gwei="${requested_max_validator_gwei:-${MAX_VALIDATOR_GWEI:-2048000000000}}"
readonly target_total_supply="${requested_target_total_supply:-${TARGET_TOTAL_SUPPLY:-}}"
readonly deposit_amount_multiplier="${requested_deposit_amount_multiplier:-${DEPOSIT_AMOUNT_MULTIPLIER:-}}"
readonly deposit_amount_divisor="${requested_deposit_amount_divisor:-${DEPOSIT_AMOUNT_DIVISOR:-}}"
readonly min_deposit_amount="${requested_min_deposit_amount:-${MIN_DEPOSIT_AMOUNT:-1}}"
readonly premine_address="${requested_premine_address:-${EL_PREMINE_ADDRESS:-0x161f5Ef2C0c1Be307CFeF2E7b1411E352a3Be01B}}"
readonly base_fee_per_gas="${requested_base_fee_per_gas:-${EL_BASE_FEE_PER_GAS:-0x2D79883D2000}}"
readonly config_name="${requested_config_name:-${CONFIG_NAME:-${chain_name}-${network_name}}}"

genesis_mnemonic=""
if [[ "${genesis_mode}" == "mnemonic" ]]; then
    genesis_mnemonic="$(
        awk '
            {
                for (index = 1; index <= NF; index++) {
                    if (result != "") result = result " "
                    result = result $index
                }
            }
            END { print result }
        ' "${mnemonic_file}"
    )"
    read -r -a mnemonic_words <<< "${genesis_mnemonic}"
    case "${#mnemonic_words[@]}" in
        12|15|18|21|24) ;;
        *) fail "Mnemonic must contain 12, 15, 18, 21, or 24 words." ;;
    esac
    for mnemonic_word in "${mnemonic_words[@]}"; do
        [[ "${mnemonic_word}" =~ ^[a-z]+$ ]] \
            || fail "Mnemonic contains an invalid word: ${mnemonic_word}"
    done
fi
readonly genesis_mnemonic
[[ "${expected_validator_count}" =~ ^[1-9][0-9]*$ ]] \
    || fail "NUMBER_OF_VALIDATORS must be a positive integer."
[[ "${genesis_timestamp}" =~ ^[1-9][0-9]*$ ]] \
    || fail "GENESIS_TIMESTAMP must be a positive Unix timestamp."
require_safe_positive_integer "MIN_VALIDATOR_GWEI" "${min_validator_gwei}"
require_safe_positive_integer "MAX_VALIDATOR_GWEI" "${max_validator_gwei}"
(( min_validator_gwei <= max_validator_gwei )) \
    || fail "MIN_VALIDATOR_GWEI must not exceed MAX_VALIDATOR_GWEI."

require_safe_positive_integer "TARGET_TOTAL_SUPPLY" "${target_total_supply}"
require_safe_positive_integer "DEPOSIT_AMOUNT_MULTIPLIER" "${deposit_amount_multiplier}"
require_safe_positive_integer "DEPOSIT_AMOUNT_DIVISOR" "${deposit_amount_divisor}"
[[ "${min_deposit_amount}" =~ ^[1-9][0-9]*$ ]] \
    || fail "MIN_DEPOSIT_AMOUNT must be a positive whole-token amount."
[[ "${premine_address}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || fail "EL_PREMINE_ADDRESS is invalid: ${premine_address}"
[[ "${base_fee_per_gas}" =~ ^0x[0-9a-fA-F]+$ ]] \
    || fail "EL_BASE_FEE_PER_GAS must be a hexadecimal quantity."
[[ "${chain_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "CHAIN_NAME is invalid: ${chain_name}"
[[ "${network_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "NETWORK_NAME is invalid: ${network_name}"
[[ "${config_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] \
    || fail "GENESIS_CONFIG_NAME is invalid: ${config_name}"
[[ "${config_name}" == "${chain_name}-${network_name}" ]] \
    || fail "CONFIG_NAME must equal CHAIN_NAME-NETWORK_NAME (${chain_name}-${network_name})."
[[ "${GENESIS_FORK_VERSION:-}" =~ ^0x[0-9a-fA-F]{8}$ ]] \
    || fail "GENESIS_FORK_VERSION is invalid in ${config_dir}/values.env."
[[ "${CAPELLA_FORK_VERSION:-}" =~ ^0x[0-9a-fA-F]{8}$ ]] \
    || fail "CAPELLA_FORK_VERSION is invalid in ${config_dir}/values.env."
[[ "${DEPOSIT_CONTRACT_ADDRESS:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || fail "DEPOSIT_CONTRACT_ADDRESS is invalid in ${config_dir}/values.env."
(( min_validator_gwei <= max_exact_integer / deposit_amount_divisor )) \
    || fail "MIN_VALIDATOR_GWEI and DEPOSIT_AMOUNT_DIVISOR produce an amount that is too large."
min_activation_numerator=$((min_validator_gwei * deposit_amount_divisor))
(( min_activation_numerator % deposit_amount_multiplier == 0 )) \
    || fail "The minimum activation amount cannot be represented exactly in native-token Gwei."
min_activation_public_gwei=$((min_activation_numerator / deposit_amount_multiplier))
(( min_activation_public_gwei % gwei_per_token == 0 )) \
    || fail "The minimum activation amount must be a whole native-token amount."
min_activation_amount=$((min_activation_public_gwei / gwei_per_token))
readonly min_activation_amount
parse_whole_token_amount_to_gwei "MIN_DEPOSIT_AMOUNT" "${min_deposit_amount}"
min_deposit_public_gwei="${parsed_gwei}"
(( min_deposit_public_gwei % deposit_amount_divisor == 0 )) \
    || fail "MIN_DEPOSIT_AMOUNT cannot be represented exactly with DEPOSIT_AMOUNT_DIVISOR."
(( min_activation_public_gwei >= min_deposit_public_gwei )) \
    || fail "Deposit amount settings are inconsistent."

function write_deposit_settings() {
    local destination="$1"
    local validators_root="$2"

    jq -n \
        --arg chain "${chain_name}" \
        --arg genesis_fork_version "${GENESIS_FORK_VERSION}" \
        --arg exit_fork_version "${CAPELLA_FORK_VERSION}" \
        --arg genesis_validator_root "${validators_root}" \
        --argjson multiplier "${deposit_amount_multiplier}" \
        --argjson divisor "${deposit_amount_divisor}" \
        --argjson min_activation_amount "${min_activation_amount}" \
        --argjson min_deposit_amount "${min_deposit_amount}" \
        '{
            network_name: $chain,
            genesis_fork_version: $genesis_fork_version,
            exit_fork_version: $exit_fork_version,
            genesis_validator_root: $genesis_validator_root,
            multiplier: $multiplier,
            divisor: $divisor,
            min_activation_amount: $min_activation_amount,
            min_deposit_amount: $min_deposit_amount
        }' > "${destination}"
}

if [[ "${prepare_deposit_settings}" == true ]]; then
    readonly zero_validators_root="0x0000000000000000000000000000000000000000000000000000000000000000"
    write_deposit_settings "${config_dir}/deposit-settings.json" "${zero_validators_root}"
    printf 'Created Genesis participation settings: %s\n' "${config_dir}/deposit-settings.json"
    exit 0
fi
if [[ "${genesis_mode}" == "deposit-data" ]]; then
    participation_settings="${config_dir}/deposit-settings.json"
    [[ -s "${participation_settings}" ]] \
        || fail "Genesis participation settings are missing. Run --prepare-deposit-settings first."
    jq -e \
        --arg chain "${chain_name}" \
        --arg genesis_fork_version "${GENESIS_FORK_VERSION}" \
        --arg exit_fork_version "${CAPELLA_FORK_VERSION}" \
        --argjson multiplier "${deposit_amount_multiplier}" \
        --argjson divisor "${deposit_amount_divisor}" \
        --argjson min_activation_amount "${min_activation_amount}" \
        --argjson min_deposit_amount "${min_deposit_amount}" '
            . == {
                network_name: $chain,
                genesis_fork_version: $genesis_fork_version,
                exit_fork_version: $exit_fork_version,
                genesis_validator_root: "0x0000000000000000000000000000000000000000000000000000000000000000",
                multiplier: $multiplier,
                divisor: $divisor,
                min_activation_amount: $min_activation_amount,
                min_deposit_amount: $min_deposit_amount
            }
        ' "${participation_settings}" >/dev/null \
        || fail "values.env no longer matches the published Genesis participation settings."
fi
if [[ "${genesis_mode}" == "mnemonic" ]]; then
    [[ "${VALIDATOR_BALANCE_GWEI:-}" =~ ^[1-9][0-9]*$ ]] \
        || fail "VALIDATOR_BALANCE_GWEI must be a positive integer in ${config_dir}/values.env."
    (( VALIDATOR_BALANCE_GWEI >= min_validator_gwei \
        && VALIDATOR_BALANCE_GWEI <= max_validator_gwei )) \
        || fail "VALIDATOR_BALANCE_GWEI is outside the accepted validator range."
    [[ "${WITHDRAWAL_ADDRESS:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
        || fail "WITHDRAWAL_ADDRESS is invalid in ${config_dir}/values.env."
    [[ "${WITHDRAWAL_TYPE:-}" =~ ^0x[0-9a-fA-F]{2}$ ]] \
        || fail "WITHDRAWAL_TYPE must contain exactly one byte in ${config_dir}/values.env."
fi

if [[ -d "${output_dir}" && -n "$(find "${output_dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "Output directory is not empty: ${output_dir}"
fi
mkdir -p "${output_dir}"

runtime_dir="$(mktemp -d "${config_dir}/.genesis-runtime.XXXXXX")"
function cleanup() {
    rm -rf -- "${runtime_dir}"
}
trap cleanup EXIT

runtime_config_dir="${runtime_dir}/config"
runtime_output_dir="${runtime_dir}/generated"
runtime_metadata_dir="${runtime_output_dir}/metadata"
runtime_parsed_dir="${runtime_output_dir}/parsed"
runtime_values="${runtime_config_dir}/values.env"
runtime_genesis="${runtime_metadata_dir}/genesis.json"
runtime_config="${runtime_metadata_dir}/config.yaml"
runtime_prysm_config="${runtime_dir}/config.prysm.yaml"
additional_validators="${runtime_config_dir}/cl/additional-validators.txt"
parsed_genesis="${runtime_parsed_dir}/parsedConsensusGenesis.json"

mkdir -p "${runtime_config_dir}/el" "${runtime_config_dir}/cl" \
    "${runtime_metadata_dir}" "${runtime_parsed_dir}"
install -m 644 "${config_dir}/values.env" "${runtime_values}"
install -m 644 "${config_dir}/el/genesis-config.yaml" "${runtime_config_dir}/el/genesis-config.yaml"
install -m 644 "${config_dir}/cl/config.yaml" "${runtime_config_dir}/cl/config.yaml"
install -m 644 "${config_dir}/cl/mnemonics.yaml" "${runtime_config_dir}/cl/mnemonics.yaml"

if [[ "${genesis_mode}" == "deposit-data" ]]; then
    printf '[]\n' > "${runtime_config_dir}/cl/mnemonics.yaml"
else
    printf -- \
        '- mnemonic: "%s"\n  count: %s\n  balance: %s\n  wd_address: %s\n  wd_prefix: %s\n' \
        "${genesis_mnemonic}" \
        "${expected_validator_count}" \
        "${VALIDATOR_BALANCE_GWEI}" \
        "${WITHDRAWAL_ADDRESS}" \
        "${WITHDRAWAL_TYPE}" \
        > "${runtime_config_dir}/cl/mnemonics.yaml"
    chmod 600 "${runtime_config_dir}/cl/mnemonics.yaml"
fi

readonly genesis_fork_version="${GENESIS_FORK_VERSION}"

printf 'Genesis validator source: %s\n' "${genesis_mode}"

function prepare_genesis_deposits() {
    local deposit_file
    local pubkey
    local withdrawal_credentials
    local amount
    local fork_version
    local network_name
    local normalized_pubkey
    local expected_fork_clean="${genesis_fork_version#0x}"
    local unique_records
    local pubkeys_file="${runtime_dir}/deposit-pubkeys.txt"
    local -a deposit_files

    mapfile -t deposit_files < <(
        find "${deposits_dir}" -type f -name 'deposit_data-*.json' -print | sort
    )
    (( ${#deposit_files[@]} > 0 )) \
        || fail "No deposit_data-*.json files found under ${deposits_dir}."

    : > "${additional_validators}"
    : > "${pubkeys_file}"
    total_records=0
    total_staked_gwei=0

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
                || fail "Fork version mismatch for ${pubkey}: expected ${genesis_fork_version}, got ${fork_version}"
            [[ "${network_name}" == "${expected_deposit_network_name}" ]] \
                || fail "Network name mismatch for ${pubkey}: expected ${expected_deposit_network_name}, got ${network_name}"

            normalized_pubkey="0x${pubkey,,}"
            printf '%s\n' "${normalized_pubkey}" >> "${pubkeys_file}"
            printf '%s:0x%s:%s\n' \
                "${normalized_pubkey}" "${withdrawal_credentials,,}" "${amount}" \
                >> "${additional_validators}"
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

    unique_records="$(sort -u "${pubkeys_file}" | wc -l | tr -d ' ')"
    (( total_records == unique_records )) || fail "Duplicate validator pubkey detected."
    [[ "${total_records}" -eq "${expected_validator_count}" ]] \
        || fail "Validator count mismatch: expected ${expected_validator_count}, found ${total_records}."
    chmod 600 "${additional_validators}"

    printf 'Validated deposit files: %s\n' "${#deposit_files[@]}"
    printf 'Validated validators: %s\n' "${total_records}"
    printf 'Total stake (Gwei): %s\n' "${total_staked_gwei}"
}

total_records=0
total_staked_gwei=0
if [[ "${genesis_mode}" == "deposit-data" ]]; then
    prepare_genesis_deposits
else
    total_records="${expected_validator_count}"
    total_staked_gwei=$((expected_validator_count * VALIDATOR_BALANCE_GWEI))
    printf 'Validated mnemonic validators: %s\n' "${total_records}"
    printf 'Total stake (Gwei): %s\n' "${total_staked_gwei}"
fi
(( total_staked_gwei > 0 )) || fail "Unable to calculate total genesis validator stake."
(( total_staked_gwei % 1000000000 == 0 )) \
    || fail "Total validator stake must be a whole consensus staking unit."

total_staked_units=$((total_staked_gwei / 1000000000))
(( total_staked_units <= max_exact_integer / deposit_amount_divisor )) \
    || fail "Genesis validator stake and DEPOSIT_AMOUNT_DIVISOR produce an amount that is too large."
total_staked_native_numerator=$((total_staked_units * deposit_amount_divisor))
(( total_staked_native_numerator % deposit_amount_multiplier == 0 )) \
    || fail "Genesis validator stake cannot be represented as whole native tokens."
total_staked_supply=$((total_staked_native_numerator / deposit_amount_multiplier))
premine_supply=$((target_total_supply - total_staked_supply))
(( premine_supply > 0 )) || fail "Calculated execution-layer premine is not positive."
premine_wei="${premine_supply}000000000000000000"

cat >> "${runtime_values}" <<RUNTIME_VALUES

# Per-run values written by generate-abpos-genesis.sh.
export NUMBER_OF_VALIDATORS="${expected_validator_count}"
export GENESIS_TIMESTAMP="${genesis_timestamp}"
export CONFIG_NAME="${config_name}"
export EL_PREMINE_COUNT="0"
export EL_PREMINE_AMOUNT="${premine_supply}"
RUNTIME_VALUES

if [[ "${genesis_mode}" == "deposit-data" ]]; then
    printf 'export CL_ADDITIONAL_VALIDATORS="cl/additional-validators.txt"\n' \
        >> "${runtime_values}"
fi

docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "${runtime_output_dir}:/data" \
    -v "${runtime_config_dir}:/config:ro" \
    "${generator_image}" \
    el

[[ -s "${runtime_genesis}" ]] \
    || fail "Genesis generator did not create the execution genesis.json."

premine_key="$(
    jq -r --arg address "${premine_address,,}" '
        [.alloc | keys[] | select(ascii_downcase == $address)] | first // empty
    ' "${runtime_genesis}"
)"
[[ -n "${premine_key}" ]] \
    || fail "EL premine address is absent from the generated execution genesis: ${premine_address}"

jq \
    --arg base_fee_per_gas "${base_fee_per_gas}" '
        .baseFeePerGas = $base_fee_per_gas |
        .alloc |= with_entries(
            select(
                (.key | ascii_downcase | test("^0x0{38}[0-9a-f]{2}$"))
                | not
            )
        )
    ' "${runtime_genesis}" > "${runtime_genesis}.tmp"
mv -f -- "${runtime_genesis}.tmp" "${runtime_genesis}"
[[ "$(jq -r '.timestamp | tostring' "${runtime_genesis}")" == "${genesis_timestamp}" ]] \
    || fail "Generated execution genesis timestamp is incorrect."
[[ "$(jq -r --arg key "${premine_key}" '.alloc[$key].balance' "${runtime_genesis}")" == "${premine_wei}" ]] \
    || fail "Generated execution genesis premine is incorrect."
[[ "$(jq -r '.baseFeePerGas' "${runtime_genesis}")" == "${base_fee_per_gas}" ]] \
    || fail "Failed to set the execution genesis base fee."
[[ "$(jq '[.alloc | keys[] | select(ascii_downcase | test("^0x0{38}[0-9a-f]{2}$"))] | length' "${runtime_genesis}")" -eq 0 ]] \
    || fail "Failed to remove reserved low-address allocations from the execution genesis."
[[ "$(jq -r '.config.chainId' "${runtime_genesis}")" == "${CHAIN_ID}" ]] \
    || fail "Generated execution genesis chain ID is incorrect."
[[ "$(jq -r '.config.depositContractAddress | ascii_downcase' "${runtime_genesis}")" == "${DEPOSIT_CONTRACT_ADDRESS,,}" ]] \
    || fail "Generated execution genesis deposit contract address is incorrect."

docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "${runtime_output_dir}:/data" \
    -v "${runtime_config_dir}:/config:ro" \
    "${generator_image}" \
    cl

[[ -s "${runtime_metadata_dir}/genesis.ssz" ]] || fail "Genesis generator did not create genesis.ssz."
[[ -s "${runtime_config}" ]] || fail "Genesis generator did not create config.yaml."
[[ -s "${parsed_genesis}" ]] || fail "Genesis generator did not create parsedConsensusGenesis.json."

[[ "$(awk -F: '$1 == "MIN_GENESIS_ACTIVE_VALIDATOR_COUNT" { gsub(/[[:space:]]/, "", $2); print $2 }' "${runtime_config}")" == "${expected_validator_count}" ]] \
    || fail "Generated consensus config has an incorrect validator count."
[[ "$(awk -F: '$1 == "MIN_GENESIS_TIME" { gsub(/[[:space:]]/, "", $2); print $2 }' "${runtime_config}")" == "${genesis_timestamp}" ]] \
    || fail "Generated consensus config has an incorrect genesis timestamp."

awk \
    -v slot_duration_ms="${SLOT_DURATION_MS:-$((SLOT_DURATION_IN_SECONDS * 1000))}" '
    /^GOSSIP_MAX_SIZE:/ || /^MAX_CHUNK_SIZE:/ { next }
    { print }
    /^SECONDS_PER_SLOT:/ { print "SLOT_DURATION_MS: " slot_duration_ms }
    END {
        print ""
        print "BASE_REWARD_FACTOR: 8"
        print ""
        print "GLOAS_FORK_VERSION: 0xffffffff"
        print "GLOAS_FORK_EPOCH: 18446744073709551615"
    }
' "${runtime_config}" > "${runtime_prysm_config}"

generated_count="$(jq '.validators | length' "${parsed_genesis}")"
[[ "${generated_count}" -eq "${expected_validator_count}" ]] \
    || fail "Generated validator count mismatch: expected ${expected_validator_count}, got ${generated_count}."

if [[ "${genesis_mode}" == "deposit-data" ]]; then
    cut -d: -f1 "${additional_validators}" | sort > "${runtime_dir}/input-pubkeys.txt"
    jq -r '.validators[].pubkey | ascii_downcase' "${parsed_genesis}" | sort \
        > "${runtime_dir}/genesis-pubkeys.txt"
    diff -q "${runtime_dir}/input-pubkeys.txt" "${runtime_dir}/genesis-pubkeys.txt" >/dev/null \
        || fail "Generated genesis validator set does not match the accepted deposit data."
else
    [[ "$(
        jq --arg expected_balance "${VALIDATOR_BALANCE_GWEI}" '
            [.validators[]
                | select((.effective_balance | tostring) != $expected_balance)]
            | length
        ' "${parsed_genesis}"
    )" -eq 0 ]] \
        || fail "Generated mnemonic validator balance does not match VALIDATOR_BALANCE_GWEI."
fi

deposit_contract_address="$(
    awk -F: '$1 == "DEPOSIT_CONTRACT_ADDRESS" {
        value = substr($0, index($0, ":") + 1)
        gsub(/[[:space:]\047\042]/, "", value)
        print value
        exit
    }' "${runtime_config}"
)"
[[ "${deposit_contract_address}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || fail "Unable to read DEPOSIT_CONTRACT_ADDRESS from ${runtime_config}."
[[ "${deposit_contract_address,,}" == "$(jq -r '.config.depositContractAddress | ascii_downcase' "${runtime_genesis}")" ]] \
    || fail "Deposit contract address differs between the generated consensus and execution files."

deposit_block_hash="$(jq -r '.eth1_data.block_hash // empty' "${parsed_genesis}")"
genesis_validators_root="$(jq -r '.genesis_validators_root // empty' "${parsed_genesis}")"
[[ "${deposit_block_hash}" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || fail "Generated deposit contract block hash is invalid."
[[ "${genesis_validators_root}" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || fail "Generated genesis validators root is invalid."

install -m 644 "${runtime_genesis}" "${output_dir}/genesis.json"
install -m 644 "${runtime_metadata_dir}/genesis.ssz" "${output_dir}/genesis.ssz"
install -m 644 "${runtime_config}" "${output_dir}/config.yaml"
install -m 644 "${runtime_prysm_config}" "${output_dir}/config.prysm.yaml"
install -m 644 "${runtime_metadata_dir}/deposit_contract_block.txt" "${output_dir}/deposit_contract_block.txt"
install -m 644 "${runtime_metadata_dir}/deposit_contract_block.txt" "${output_dir}/deploy_block.txt"
printf '%s\n' "${deposit_contract_address}" > "${output_dir}/deposit_contract.txt"
printf '%s\n' "${deposit_block_hash}" > "${output_dir}/deposit_contract_block_hash.txt"
printf '%s\n' "${genesis_validators_root}" > "${output_dir}/genesis_validators_root.txt"
write_deposit_settings "${output_dir}/deposit-settings.json" "${genesis_validators_root}"

printf 'Generated AB PoS genesis files in %s\n' "${output_dir}"
printf 'Chain: %s\n' "${chain_name}"
printf 'Network: %s\n' "${network_name}"
printf 'Consensus config: %s\n' "${config_name}"
printf 'Validator source: %s\n' "${genesis_mode}"
printf 'Validators: %s\n' "${generated_count}"
printf 'Total stake (Gwei): %s\n' "${total_staked_gwei}"
printf 'Execution premine: %s\n' "${premine_supply}"
printf 'Genesis validators root: %s\n' "${genesis_validators_root}"
