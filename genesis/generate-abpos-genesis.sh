#!/usr/bin/env bash

set -euo pipefail

# Build an AB PoS execution genesis and consensus genesis state from public
# deposit data. This script intentionally does not handle validator keystores,
# node deployment, bootnode discovery, or JWT secrets.

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_dir="$(cd "${script_dir}/.." && pwd)"

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

function usage() {
    cat <<'USAGE'
Usage:
  ./generate-abpos-genesis.sh DEPOSITS_DIR [OUTPUT_DIR]

Required environment variable:
  EXPECTED_VALIDATOR_COUNT   Approved number of genesis validators

Optional environment variables:
  ABPOS_NETWORK              Network template to use (default: testnet)
  GENESIS_TIMESTAMP          MIN_GENESIS_TIME; default is now plus 300 seconds
  DEPOSIT_NETWORK_NAME       Expected Deposit CLI network name (default: abcore)
  MIN_VALIDATOR_GWEI         Minimum accepted amount (default: 32000000000)
  MAX_VALIDATOR_GWEI         Maximum accepted amount (default: 2048000000000)
  GENESIS_GENERATOR_IMAGE    Generator image (default: ethpandaops/ethereum-genesis-generator:6.1.6)
  TARGET_TOTAL_SUPPLY_AB     Total AB supply (default: 100000000000)
  KAB_MULTIPLIER             AB represented by one staked ETH (default: 1000)
  EL_PREMINE_ADDRESS         Address whose genesis balance is adjusted

For a production build, pin GENESIS_GENERATOR_IMAGE to a reviewed immutable
image digest and independently review every generated file before publication.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
[[ "$#" -ge 1 && "$#" -le 2 ]] || { usage >&2; exit 2; }

[[ -d "$1" ]] || fail "Deposit directory not found: $1"
readonly deposits_dir="$(cd "$1" && pwd)"
readonly output_dir="${2:-${script_dir}/output}"
readonly network="${ABPOS_NETWORK:-testnet}"
readonly template_dir="${repository_dir}/abpos/${network}/share"
readonly expected_validator_count="${EXPECTED_VALIDATOR_COUNT:-}"
readonly genesis_timestamp="${GENESIS_TIMESTAMP:-$(( $(date +%s) + 300 ))}"
readonly deposit_network_name="${DEPOSIT_NETWORK_NAME:-abcore}"
readonly min_validator_gwei="${MIN_VALIDATOR_GWEI:-32000000000}"
readonly max_validator_gwei="${MAX_VALIDATOR_GWEI:-2048000000000}"
readonly generator_image="${GENESIS_GENERATOR_IMAGE:-ethpandaops/ethereum-genesis-generator:6.1.6}"
readonly target_total_supply_ab="${TARGET_TOTAL_SUPPLY_AB:-100000000000}"
readonly kab_multiplier="${KAB_MULTIPLIER:-1000}"
readonly premine_address="${EL_PREMINE_ADDRESS:-0x161f5Ef2C0c1Be307CFeF2E7b1411E352a3Be01B}"

for command_name in docker jq awk sort diff; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "Required command not found: ${command_name}"
done
[[ "${expected_validator_count}" =~ ^[1-9][0-9]*$ ]] \
    || fail "EXPECTED_VALIDATOR_COUNT must be a positive integer."
[[ "${genesis_timestamp}" =~ ^[1-9][0-9]*$ ]] \
    || fail "GENESIS_TIMESTAMP must be a positive Unix timestamp."
[[ "${target_total_supply_ab}" =~ ^[1-9][0-9]*$ ]] \
    || fail "TARGET_TOTAL_SUPPLY_AB must be a positive integer."
[[ "${kab_multiplier}" =~ ^[1-9][0-9]*$ ]] \
    || fail "KAB_MULTIPLIER must be a positive integer."
[[ "${min_validator_gwei}" =~ ^[0-9]+$ && "${max_validator_gwei}" =~ ^[0-9]+$ ]] \
    || fail "Validator amount limits must be non-negative integers."
(( min_validator_gwei <= max_validator_gwei )) \
    || fail "MIN_VALIDATOR_GWEI must not exceed MAX_VALIDATOR_GWEI."
[[ "${premine_address}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || fail "EL_PREMINE_ADDRESS is invalid: ${premine_address}"
[[ -d "${template_dir}" ]] || fail "Network template directory not found: ${template_dir}"

for required_file in genesis.json config.yaml config.prysm.yaml deposit_contract_block.txt; do
    [[ -s "${template_dir}/${required_file}" ]] \
        || fail "Required network template is missing: ${template_dir}/${required_file}"
done

if [[ -d "${output_dir}" && -n "$(find "${output_dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "Output directory is not empty: ${output_dir}"
fi
mkdir -p "${output_dir}"

runtime_dir="$(mktemp -d "${script_dir}/.genesis-runtime.XXXXXX")"
function cleanup() {
    rm -rf -- "${runtime_dir}"
}
trap cleanup EXIT

runtime_config="${runtime_dir}/config.yaml"
runtime_prysm_config="${runtime_dir}/config.prysm.yaml"
runtime_genesis="${runtime_dir}/genesis.json"
additional_validators="${runtime_dir}/additional-validators.txt"
parsed_genesis="${runtime_dir}/parsedConsensusGenesis.json"

install -m 644 "${template_dir}/config.yaml" "${runtime_config}"
install -m 644 "${template_dir}/config.prysm.yaml" "${runtime_prysm_config}"
install -m 644 "${template_dir}/genesis.json" "${runtime_genesis}"
printf '[]\n' > "${runtime_dir}/mnemonics.yaml"

function update_consensus_config() {
    local path="$1"
    local temporary_path="${path}.tmp"

    awk \
        -v validators="${expected_validator_count}" \
        -v timestamp="${genesis_timestamp}" '
        /^MIN_GENESIS_ACTIVE_VALIDATOR_COUNT:/ {
            print "MIN_GENESIS_ACTIVE_VALIDATOR_COUNT: " validators
            next
        }
        /^MIN_GENESIS_TIME:/ {
            print "MIN_GENESIS_TIME: " timestamp
            next
        }
        { print }
    ' "${path}" > "${temporary_path}"
    mv -f -- "${temporary_path}" "${path}"

    [[ "$(awk -F: '$1 == "MIN_GENESIS_ACTIVE_VALIDATOR_COUNT" { count++ } END { print count + 0 }' "${path}")" -eq 1 ]] \
        || fail "${path} must contain exactly one MIN_GENESIS_ACTIVE_VALIDATOR_COUNT entry."
    [[ "$(awk -F: '$1 == "MIN_GENESIS_TIME" { count++ } END { print count + 0 }' "${path}")" -eq 1 ]] \
        || fail "${path} must contain exactly one MIN_GENESIS_TIME entry."
    [[ "$(awk -F: '$1 == "MIN_GENESIS_ACTIVE_VALIDATOR_COUNT" { gsub(/[[:space:]]/, "", $2); print $2 }' "${path}")" == "${expected_validator_count}" ]] \
        || fail "Failed to update MIN_GENESIS_ACTIVE_VALIDATOR_COUNT in ${path}."
    [[ "$(awk -F: '$1 == "MIN_GENESIS_TIME" { gsub(/[[:space:]]/, "", $2); print $2 }' "${path}")" == "${genesis_timestamp}" ]] \
        || fail "Failed to update MIN_GENESIS_TIME in ${path}."
}

update_consensus_config "${runtime_config}"
update_consensus_config "${runtime_prysm_config}"

genesis_fork_version="$(
    awk -F: '$1 == "GENESIS_FORK_VERSION" {
        value = substr($0, index($0, ":") + 1)
        gsub(/[[:space:]\047\042]/, "", value)
        print value
        exit
    }' "${runtime_config}"
)"
[[ "${genesis_fork_version}" =~ ^0x[0-9a-fA-F]{8}$ ]] \
    || fail "Unable to read GENESIS_FORK_VERSION from ${runtime_config}."

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
            [[ "${network_name}" == "${deposit_network_name}" ]] \
                || fail "Network name mismatch for ${pubkey}: expected ${deposit_network_name}, got ${network_name}"

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
prepare_genesis_deposits
(( total_staked_gwei > 0 )) || fail "Unable to calculate total genesis validator stake."
(( total_staked_gwei % 1000000000 == 0 )) \
    || fail "Total validator stake must be a whole number of ETH."

total_staked_eth=$((total_staked_gwei / 1000000000))
total_staked_ab=$((total_staked_eth * kab_multiplier))
premine_ab=$((target_total_supply_ab - total_staked_ab))
(( premine_ab > 0 )) || fail "Calculated execution-layer premine is not positive."
premine_wei="${premine_ab}000000000000000000"

premine_key="$(
    jq -r --arg address "${premine_address,,}" '
        [.alloc | keys[] | select(ascii_downcase == $address)] | first // empty
    ' "${runtime_genesis}"
)"
[[ -n "${premine_key}" ]] \
    || fail "EL premine address is absent from the execution genesis template: ${premine_address}"

jq \
    --arg premine_key "${premine_key}" \
    --arg premine_wei "${premine_wei}" \
    --argjson timestamp "${genesis_timestamp}" '
        .timestamp = $timestamp |
        .alloc[$premine_key].balance = $premine_wei
    ' "${runtime_genesis}" > "${runtime_genesis}.tmp"
mv -f -- "${runtime_genesis}.tmp" "${runtime_genesis}"
[[ "$(jq -r '.timestamp | tostring' "${runtime_genesis}")" == "${genesis_timestamp}" ]] \
    || fail "Failed to update the execution genesis timestamp."
[[ "$(jq -r --arg key "${premine_key}" '.alloc[$key].balance' "${runtime_genesis}")" == "${premine_wei}" ]] \
    || fail "Failed to update the execution genesis premine."

docker run --rm \
    -u "$(id -u):$(id -g)" \
    --entrypoint /usr/local/bin/eth-genesis-state-generator \
    -v "${runtime_dir}:/work" \
    "${generator_image}" \
    beaconchain \
    --config /work/config.yaml \
    --eth1-config /work/genesis.json \
    --mnemonics /work/mnemonics.yaml \
    --additional-validators /work/additional-validators.txt \
    --state-output /work/genesis.ssz \
    --json-output /work/parsedConsensusGenesis.json

[[ -s "${runtime_dir}/genesis.ssz" ]] || fail "Genesis generator did not create genesis.ssz."
[[ -s "${parsed_genesis}" ]] || fail "Genesis generator did not create parsedConsensusGenesis.json."

generated_count="$(jq '.validators | length' "${parsed_genesis}")"
[[ "${generated_count}" -eq "${expected_validator_count}" ]] \
    || fail "Generated validator count mismatch: expected ${expected_validator_count}, got ${generated_count}."

cut -d: -f1 "${additional_validators}" | sort > "${runtime_dir}/input-pubkeys.txt"
jq -r '.validators[].pubkey | ascii_downcase' "${parsed_genesis}" | sort \
    > "${runtime_dir}/genesis-pubkeys.txt"
diff -q "${runtime_dir}/input-pubkeys.txt" "${runtime_dir}/genesis-pubkeys.txt" >/dev/null \
    || fail "Generated genesis validator set does not match the accepted deposit data."

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
    || fail "Deposit contract address differs between consensus and execution templates."

deposit_block_hash="$(jq -r '.eth1_data.block_hash // empty' "${parsed_genesis}")"
genesis_validators_root="$(jq -r '.genesis_validators_root // empty' "${parsed_genesis}")"
[[ "${deposit_block_hash}" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || fail "Generated deposit contract block hash is invalid."
[[ "${genesis_validators_root}" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || fail "Generated genesis validators root is invalid."

install -m 644 "${runtime_genesis}" "${output_dir}/genesis.json"
install -m 644 "${runtime_dir}/genesis.ssz" "${output_dir}/genesis.ssz"
install -m 644 "${runtime_config}" "${output_dir}/config.yaml"
install -m 644 "${runtime_prysm_config}" "${output_dir}/config.prysm.yaml"
install -m 644 "${template_dir}/deposit_contract_block.txt" "${output_dir}/deposit_contract_block.txt"
printf '%s\n' "${deposit_contract_address}" > "${output_dir}/deposit_contract.txt"
printf '%s\n' "${deposit_block_hash}" > "${output_dir}/deposit_contract_block_hash.txt"
printf '%s\n' "${genesis_validators_root}" > "${output_dir}/genesis_validators_root.txt"

for optional_file in bootstrap_nodes.txt bootstrap_nodes_execution.txt; do
    if [[ -s "${template_dir}/${optional_file}" ]]; then
        install -m 644 "${template_dir}/${optional_file}" "${output_dir}/${optional_file}"
    fi
done

printf 'Generated AB PoS genesis files in %s\n' "${output_dir}"
printf 'Validators: %s\n' "${generated_count}"
printf 'Total stake (Gwei): %s\n' "${total_staked_gwei}"
printf 'Execution premine (AB): %s\n' "${premine_ab}"
printf 'Genesis validators root: %s\n' "${genesis_validators_root}"
