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
readonly generator_image="${GENESIS_GENERATOR_IMAGE:-ethpandaops/ethereum-genesis-generator:6.1.6}"
readonly target_total_supply_ab="${TARGET_TOTAL_SUPPLY_AB:-100000000000}"
readonly kab_multiplier="${KAB_MULTIPLIER:-1000}"
readonly premine_address="${EL_PREMINE_ADDRESS:-0x161f5Ef2C0c1Be307CFeF2E7b1411E352a3Be01B}"
readonly prepare_script="${script_dir}/prepare-abpos-genesis-deposits.sh"

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
[[ "${premine_address}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || fail "EL_PREMINE_ADDRESS is invalid: ${premine_address}"
[[ -x "${prepare_script}" ]] || fail "Required script is not executable: ${prepare_script}"
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

EXPECTED_VALIDATOR_COUNT="${expected_validator_count}" \
GENESIS_FORK_VERSION="${genesis_fork_version}" \
DEPOSIT_NETWORK_NAME="${deposit_network_name}" \
    "${prepare_script}" "${deposits_dir}" "${additional_validators}"

total_staked_gwei=0
while IFS=: read -r _ _ validator_amount; do
    [[ "${validator_amount}" =~ ^[1-9][0-9]*$ ]] \
        || fail "Invalid amount in generated additional-validator input: ${validator_amount}"
    total_staked_gwei=$((total_staked_gwei + validator_amount))
done < "${additional_validators}"
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
