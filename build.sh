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
  ./build.sh --check CHAIN NETWORK RELEASE_PHASE
  ./build.sh VERSION CHAIN NETWORK RELEASE_PHASE

RELEASE_PHASE must be candidate or release.
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

function require_data_line_file() {
    local path="$1"
    local label="$2"

    [[ -s "${path}" ]] || fail "required ${label} file is missing or empty: ${path}"
    [[ -n "$(effective_lines "${path}")" ]] || fail "${label} file has no usable entries: ${path}"
}

function validate_unique_line_file() {
    local path="$1"
    local label="$2"

    [[ -f "${path}" ]] || return 0
    [[ -z "$(effective_lines "${path}" | sort | uniq -d | head -n 1)" ]] \
        || fail "${label} file contains duplicate entries: ${path}"
}

function yaml_scalar() {
    local path="$1"
    local key="$2"
    local value

    value="$(awk -F: -v key="${key}" '
        $1 == key {
            value = substr($0, index($0, ":") + 1)
            sub(/[[:space:]]+#.*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "${path}")"
    case "${value}" in
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
    esac
    printf '%s\n' "${value}"
}

function require_yaml_scalar() {
    local path="$1"
    local key="$2"
    local value

    value="$(yaml_scalar "${path}" "${key}")"
    [[ -n "${value}" ]] || fail "${path} is missing required YAML key ${key}"
    printf '%s\n' "${value}"
}

function decimal_quantity() {
    local value="$1"
    local label="$2"

    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "${value}"
    elif [[ "${value}" =~ ^0x[0-9a-fA-F]+$ ]]; then
        printf '%d\n' "$((16#${value#0x}))"
    else
        fail "${label} must be a decimal or 0x-prefixed hexadecimal integer; got: ${value}"
    fi
}

function ssz_uint64_le() {
    local path="$1"
    local -a bytes
    local value=0
    local index

    read -r -a bytes <<<"$(od -An -v -tu1 -N8 "${path}")"
    [[ "${#bytes[@]}" -eq 8 ]] || fail "unable to read the genesis time from ${path}"
    for index in {0..7}; do
        (( value += bytes[index] << (index * 8) ))
    done
    printf '%s\n' "${value}"
}

function validate_network() {
    local target_chain="$1"
    local target_network="$2"
    local target_phase="$3"
    local target_config_name="${target_chain}-${target_network}"
    local target_share_dir="${root_dir}/${target_chain}/${target_network}/share"
    local required_file
    local share_entry
    local share_name
    local chain_id
    local deposit_address
    local published_deposit_address
    local deposit_block_hash
    local genesis_validators_root
    local ssz_genesis_validators_root
    local settings_genesis_fork_version
    local settings_exit_fork_version
    local settings_genesis_validators_root
    local execution_genesis_time
    local beacon_genesis_time
    local min_genesis_time
    local genesis_delay
    local terminal_total_difficulty
    local config_terminal_total_difficulty
    local deposit_block
    local deploy_block
    local seconds_per_slot
    local slot_duration_ms
    local key
    local lighthouse_value
    local prysm_value
    local -a shared_config_keys

    [[ "${target_chain}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid chain name: ${target_chain}"
    [[ "${target_network}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid network name: ${target_network}"
    case "${target_phase}" in
        candidate|release) ;;
        *) fail "RELEASE_PHASE must be candidate or release; got: ${target_phase}" ;;
    esac

    [[ -d "${target_share_dir}" ]] || fail "network share directory not found: ${target_share_dir}"
    for required_file in genesis.json genesis.ssz config.yaml config.prysm.yaml \
        deposit_contract_block.txt genesis_validators_root.txt deposit-settings.json; do
        [[ -s "${target_share_dir}/${required_file}" ]] || fail "required network file is missing or empty: ${target_share_dir}/${required_file}"
    done
    if [[ "${target_phase}" != "candidate" ]]; then
        require_data_line_file "${target_share_dir}/bootstrap_nodes.txt" "beacon bootstrap node"
        require_data_line_file "${target_share_dir}/bootstrap_nodes_execution.txt" "Geth enode"
    fi
    [[ ! -e "${target_share_dir}/jwtsecret" ]] \
        || fail "jwtsecret is node-local authentication material and must not be included in the network share"
    while IFS= read -r -d '' share_entry; do
        share_name="${share_entry##*/}"
        case "${share_name}" in
            genesis.json|genesis.ssz|config.yaml|config.prysm.yaml|\
            deposit_contract.txt|deposit_contract_block.txt|deposit_contract_block_hash.txt|\
            genesis_validators_root.txt|deposit-settings.json|deploy_block.txt|bootstrap_nodes.txt|\
            bootstrap_nodes_execution.txt|checkpoint_sync_urls.txt)
                [[ -f "${share_entry}" && ! -L "${share_entry}" ]] \
                    || fail "network share entry must be a regular file: ${share_entry}"
                ;;
            *)
                fail "unexpected file in network share: ${share_entry}"
                ;;
        esac
    done < <(find "${target_share_dir}" -mindepth 1 -maxdepth 1 -print0)

    require_command jq
    require_command od
    jq -e '
        type == "object"
        and (.config | type == "object")
        and (.config.chainId | type == "number")
        and (.config.depositContractAddress | type == "string")
        and (.alloc | type == "object")
        and ((.timestamp | type) == "number" or (.timestamp | type) == "string")
    ' \
        "${target_share_dir}/genesis.json" >/dev/null \
        || fail "genesis.json is missing required execution genesis fields"

    shared_config_keys=(
        PRESET_BASE CONFIG_NAME MIN_GENESIS_ACTIVE_VALIDATOR_COUNT MIN_GENESIS_TIME
        GENESIS_FORK_VERSION GENESIS_DELAY ALTAIR_FORK_VERSION ALTAIR_FORK_EPOCH
        BELLATRIX_FORK_VERSION BELLATRIX_FORK_EPOCH TERMINAL_TOTAL_DIFFICULTY
        TERMINAL_BLOCK_HASH TERMINAL_BLOCK_HASH_ACTIVATION_EPOCH
        CAPELLA_FORK_VERSION CAPELLA_FORK_EPOCH DENEB_FORK_VERSION DENEB_FORK_EPOCH
        ELECTRA_FORK_VERSION ELECTRA_FORK_EPOCH FULU_FORK_VERSION FULU_FORK_EPOCH
        SECONDS_PER_SLOT DEPOSIT_CHAIN_ID DEPOSIT_NETWORK_ID DEPOSIT_CONTRACT_ADDRESS
    )
    for key in "${shared_config_keys[@]}"; do
        lighthouse_value="$(require_yaml_scalar "${target_share_dir}/config.yaml" "${key}")"
        prysm_value="$(require_yaml_scalar "${target_share_dir}/config.prysm.yaml" "${key}")"
        if [[ "${key}" == "DEPOSIT_CONTRACT_ADDRESS" ]]; then
            [[ "${lighthouse_value,,}" == "${prysm_value,,}" ]] \
                || fail "${key} differs between config.yaml and config.prysm.yaml"
        else
            [[ "${lighthouse_value}" == "${prysm_value}" ]] \
                || fail "${key} differs between config.yaml and config.prysm.yaml"
        fi
    done

    [[ "$(require_yaml_scalar "${target_share_dir}/config.yaml" PRESET_BASE)" == "mainnet" ]] \
        || fail "config.yaml PRESET_BASE must be mainnet"
    [[ "$(require_yaml_scalar "${target_share_dir}/config.yaml" CONFIG_NAME)" == "${target_config_name}" ]] \
        || fail "config.yaml CONFIG_NAME must match ${target_config_name}"
    [[ "$(require_yaml_scalar "${target_share_dir}/config.yaml" GENESIS_FORK_VERSION)" =~ ^0x[0-9a-fA-F]{8}$ ]] \
        || fail "GENESIS_FORK_VERSION must contain exactly four bytes"

    chain_id="$(jq -r '.config.chainId' "${target_share_dir}/genesis.json")"
    [[ "${chain_id}" =~ ^[1-9][0-9]*$ ]] || fail "genesis.json config.chainId must be a positive integer"
    [[ "$(require_yaml_scalar "${target_share_dir}/config.yaml" DEPOSIT_CHAIN_ID)" == "${chain_id}" ]] \
        || fail "config.yaml DEPOSIT_CHAIN_ID does not match genesis.json chainId"
    [[ "$(require_yaml_scalar "${target_share_dir}/config.yaml" DEPOSIT_NETWORK_ID)" == "${chain_id}" ]] \
        || fail "config.yaml DEPOSIT_NETWORK_ID does not match genesis.json chainId"

    deposit_address="$(jq -r '.config.depositContractAddress' "${target_share_dir}/genesis.json")"
    [[ "${deposit_address}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
        || fail "genesis.json config.depositContractAddress is invalid"
    [[ "${deposit_address,,}" == "$(require_yaml_scalar "${target_share_dir}/config.yaml" DEPOSIT_CONTRACT_ADDRESS | tr '[:upper:]' '[:lower:]')" ]] \
        || fail "DEPOSIT_CONTRACT_ADDRESS does not match genesis.json"
    if [[ -f "${target_share_dir}/deposit_contract.txt" ]]; then
        published_deposit_address="$(tr -d '[:space:]' < "${target_share_dir}/deposit_contract.txt")"
        [[ "${published_deposit_address}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
            || fail "deposit_contract.txt must contain one execution address"
        [[ "${published_deposit_address,,}" == "${deposit_address,,}" ]] \
            || fail "deposit_contract.txt does not match the configured deposit contract address"
    fi

    execution_genesis_time="$(decimal_quantity "$(jq -r '.timestamp | tostring' "${target_share_dir}/genesis.json")" "genesis.json timestamp")"
    min_genesis_time="$(decimal_quantity "$(require_yaml_scalar "${target_share_dir}/config.yaml" MIN_GENESIS_TIME)" MIN_GENESIS_TIME)"
    genesis_delay="$(decimal_quantity "$(require_yaml_scalar "${target_share_dir}/config.yaml" GENESIS_DELAY)" GENESIS_DELAY)"
    beacon_genesis_time="$(ssz_uint64_le "${target_share_dir}/genesis.ssz")"
    [[ "${execution_genesis_time}" == "${min_genesis_time}" ]] \
        || fail "genesis.json timestamp does not match MIN_GENESIS_TIME"
    [[ "$((min_genesis_time + genesis_delay))" -eq "${beacon_genesis_time}" ]] \
        || fail "genesis.ssz genesis time does not equal MIN_GENESIS_TIME + GENESIS_DELAY"

    terminal_total_difficulty="$(decimal_quantity "$(jq -r '.config.terminalTotalDifficulty | tostring' "${target_share_dir}/genesis.json")" "genesis.json terminalTotalDifficulty")"
    config_terminal_total_difficulty="$(decimal_quantity "$(require_yaml_scalar "${target_share_dir}/config.yaml" TERMINAL_TOTAL_DIFFICULTY)" TERMINAL_TOTAL_DIFFICULTY)"
    [[ "${terminal_total_difficulty}" == "${config_terminal_total_difficulty}" ]] \
        || fail "TERMINAL_TOTAL_DIFFICULTY does not match genesis.json"

    deposit_block="$(tr -d '[:space:]' < "${target_share_dir}/deposit_contract_block.txt")"
    [[ "${deposit_block}" =~ ^[0-9]+$ ]] \
        || fail "deposit_contract_block.txt must contain one non-negative block number"
    if [[ -f "${target_share_dir}/deploy_block.txt" ]]; then
        deploy_block="$(tr -d '[:space:]' < "${target_share_dir}/deploy_block.txt")"
        [[ "${deploy_block}" =~ ^[0-9]+$ ]] \
            || fail "deploy_block.txt must contain one non-negative block number"
        [[ "${deploy_block}" == "${deposit_block}" ]] \
            || fail "deploy_block.txt must match deposit_contract_block.txt"
    fi
    if [[ -f "${target_share_dir}/deposit_contract_block_hash.txt" ]]; then
        deposit_block_hash="$(tr -d '[:space:]' < "${target_share_dir}/deposit_contract_block_hash.txt")"
        [[ "${deposit_block_hash}" =~ ^0x[0-9a-fA-F]{64}$ ]] \
            || fail "deposit_contract_block_hash.txt must contain one 32-byte hash"
    fi
    genesis_validators_root="$(tr -d '[:space:]' < "${target_share_dir}/genesis_validators_root.txt")"
    [[ "${genesis_validators_root}" =~ ^0x[0-9a-fA-F]{64}$ ]] \
        || fail "genesis_validators_root.txt must contain one 32-byte root"
    ssz_genesis_validators_root="0x$(od -An -v -tx1 -j8 -N32 \
        "${target_share_dir}/genesis.ssz" | tr -d '[:space:]')"
    [[ "${ssz_genesis_validators_root,,}" == "${genesis_validators_root,,}" ]] \
        || fail "genesis_validators_root.txt does not match genesis.ssz"

    jq -e \
        --arg chain "${target_chain}" \
        '
            type == "object"
            and (keys | sort) == ([
                "network_name",
                "genesis_fork_version",
                "exit_fork_version",
                "genesis_validator_root",
                "multiplier",
                "min_activation_amount",
                "min_deposit_amount"
            ] | sort)
            and .network_name == $chain
            and (.genesis_fork_version | test("^0x[0-9a-fA-F]{8}$"))
            and (.exit_fork_version | test("^0x[0-9a-fA-F]{8}$"))
            and (.genesis_validator_root | test("^0x[0-9a-fA-F]{64}$"))
            and (.multiplier | type == "number" and . > 0)
            and (.min_activation_amount | type == "number" and . > 0)
            and (.min_deposit_amount | type == "number" and . > 0)
            and .min_activation_amount >= .min_deposit_amount
        ' "${target_share_dir}/deposit-settings.json" >/dev/null \
        || fail "deposit-settings.json is invalid for ${target_chain}/${target_network}"
    settings_genesis_fork_version="$(jq -r \
        '.genesis_fork_version' "${target_share_dir}/deposit-settings.json")"
    settings_exit_fork_version="$(jq -r \
        '.exit_fork_version' "${target_share_dir}/deposit-settings.json")"
    settings_genesis_validators_root="$(jq -r \
        '.genesis_validator_root' "${target_share_dir}/deposit-settings.json")"
    [[ "${settings_genesis_fork_version,,}" == \
        "$(require_yaml_scalar "${target_share_dir}/config.yaml" GENESIS_FORK_VERSION | tr '[:upper:]' '[:lower:]')" ]] \
        || fail "deposit-settings.json genesis_fork_version does not match config.yaml"
    [[ "${settings_exit_fork_version,,}" == \
        "$(require_yaml_scalar "${target_share_dir}/config.yaml" CAPELLA_FORK_VERSION | tr '[:upper:]' '[:lower:]')" ]] \
        || fail "deposit-settings.json exit_fork_version does not match CAPELLA_FORK_VERSION"
    [[ "${settings_genesis_validators_root,,}" == "${genesis_validators_root,,}" ]] \
        || fail "deposit-settings.json genesis_validator_root does not match genesis_validators_root.txt"

    seconds_per_slot="$(decimal_quantity "$(require_yaml_scalar "${target_share_dir}/config.yaml" SECONDS_PER_SLOT)" SECONDS_PER_SLOT)"
    (( seconds_per_slot > 0 )) || fail "SECONDS_PER_SLOT must be positive"
    slot_duration_ms="$(yaml_scalar "${target_share_dir}/config.prysm.yaml" SLOT_DURATION_MS)"
    if [[ -n "${slot_duration_ms}" ]]; then
        [[ "${slot_duration_ms}" =~ ^[0-9]+$ && "${slot_duration_ms}" -eq "$((seconds_per_slot * 1000))" ]] \
            || fail "config.prysm.yaml SLOT_DURATION_MS must equal SECONDS_PER_SLOT * 1000"
    fi

    validate_line_file "${target_share_dir}/bootstrap_nodes.txt" "beacon bootstrap node" '^enr:[A-Za-z0-9_-]+$'
    validate_line_file "${target_share_dir}/bootstrap_nodes_execution.txt" "Geth enode" '^enode://[0-9a-fA-F]{128}@[^[:space:]@]+:[0-9]{1,5}$'
    validate_line_file "${target_share_dir}/checkpoint_sync_urls.txt" "checkpoint URL" '^https?://[^[:space:]]+$'
    validate_unique_line_file "${target_share_dir}/bootstrap_nodes.txt" "beacon bootstrap node"
    validate_unique_line_file "${target_share_dir}/bootstrap_nodes_execution.txt" "Geth enode"
    validate_unique_line_file "${target_share_dir}/checkpoint_sync_urls.txt" "checkpoint URL"

    if [[ "${target_phase}" == "candidate" ]]; then
        printf '%s\n' \
            "INFO: Genesis Candidate validation allows empty bootstrap node files." \
            "      Populate both lists before building the final Genesis Release."
    elif [[ ! -s "${target_share_dir}/checkpoint_sync_urls.txt" ]]; then
        printf '%s\n' \
            "INFO: checkpoint_sync_urls.txt is absent." \
            "      Nodes must use --genesis or provide --checkpoint-url."
    fi

    printf 'Validated %s/%s network files in %s mode.\n' \
        "${target_chain}" "${target_network}" "${target_phase}"
}

if [[ "${1:-}" == "--check" ]]; then
    [[ "$#" -eq 4 ]] || { usage >&2; exit 2; }
    validate_network "$2" "$3" "$4"
    exit 0
fi

[[ "$#" -eq 4 ]] || { usage >&2; exit 2; }
readonly version="$1"
readonly chain="$2"
readonly network="$3"
readonly release_phase="$4"
readonly share_dir="${root_dir}/${chain}/${network}/share"
readonly artifact="${build_dir}/${chain}-${network}-${version}.tar.gz"

[[ "${version}" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "invalid VERSION: ${version}"
validate_network "${chain}" "${network}" "${release_phase}"
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
