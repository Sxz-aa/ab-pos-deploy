#!/usr/bin/env bash

set -euo pipefail

# Install and operate an AB PoS node with Docker or native binaries.

readonly script_version="0.3.0"
readonly default_release_repo="${ABPOS_RELEASE_REPO:-abdaodev/ab-pos-deploy}"
readonly default_chain_name="${ABPOS_CHAIN_NAME:-abcore}"
readonly default_root_dir="${ABPOS_ROOT_DIR:-/data}"
readonly github_api_url="${GITHUB_API_URL:-https://api.github.com}"
readonly geth_image_override="${GETH_DOCKER_IMAGE:-}"
readonly prysm_beacon_image_override="${PRYSM_BEACON_IMAGE:-}"
readonly prysm_validator_image_override="${PRYSM_VALIDATOR_IMAGE:-}"
readonly lighthouse_image_override="${LIGHTHOUSE_IMAGE:-}"
readonly deposit_cli_image_override="${DEPOSIT_CLI_IMAGE:-}"
readonly geth_binary_url_override="${AB_GETH_BINARY_URL:-}"
readonly geth_binary_checksum_url_override="${AB_GETH_BINARY_SHA256_URL:-}"
readonly prysm_release_version_override="${PRYSM_RELEASE_VERSION:-}"
readonly lighthouse_binary_url_override="${AB_LIGHTHOUSE_BINARY_URL:-}"
readonly lighthouse_binary_checksum_url_override="${AB_LIGHTHOUSE_BINARY_SHA256_URL:-}"
readonly deposit_cli_release_version_override="${DEPOSIT_CLI_RELEASE_VERSION:-}"
readonly gwei_per_token=1000000000
readonly max_exact_integer=9007199254740991

function color() {
    printf '\033[%sm%s\033[0m\n' "$@"
}

function fail() {
    color "31" "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<'USAGE'
AB PoS node installer.

Usage:
  ab-pos.sh [chain] <network> [consensus-client] [geth] [options]
  ab-pos.sh [chain] <network> --status
  ab-pos.sh [chain] <network> --logs [service]
  ab-pos.sh [chain] <network> --stop
  ab-pos.sh [chain] <network> --restart
  ab-pos.sh [chain] <network> --import-keys

Arguments:
  chain               Chain name; default: abcore
  network             testnet or mainnet
  consensus-client    prysm or lighthouse; detected for an installed node
  execution-client    geth; optional because Geth is currently the only choice

On an interactive installation, missing operator choices are requested from
the terminal. Non-interactive installations must specify them explicitly.

Node modes:
  Default              RPC node, synchronized from checkpoint
  --validator          Validator node, synchronized from checkpoint
  --genesis            Synchronize from genesis instead of checkpoint
  --archive            Run Geth in archive mode

Validator behavior:
  --validator
      Run a Validator Client. Existing keystores are imported automatically
      when the Validator wallet is empty.

  --generate-keys
      Generate validator keys and deposit data, then exit unless --validator
      is also supplied.

  --import-keys
      Import keystores into an installed Validator wallet and restart only the
      Validator Client.

Core options:
  --withdrawal-address ADDRESS   Prompted when generating keys if omitted
  --amount AMOUNT                Per-validator Deposit amount; prompted if omitted
  --fee-recipient ADDRESS        Prompted when no saved value exists
  --extra-data TEXT              Geth block extra data; at most 32 UTF-8 bytes
  --graffiti TEXT                Validator graffiti; at most 32 UTF-8 bytes
                                Requires --validator. Both settings are saved;
                                pass "" to restore the client default.
  --validator-count NUMBER       Number of keys; prompted if omitted
  --validator-start-index NUMBER Default: 0
  --mnemonic-file PATH           Default: <data-dir>/keys/mnemonic.txt
  --deposit-settings FILE        Public settings for key-only generation
  --checkpoint-url URL           Override the Release checkpoint URL
  --release VERSION              Release tag; default: latest
  --release-repo OWNER/REPO      Default: abdaodev/ab-pos-deploy
  --release-url URL              Download a specific .tar.gz Release archive
  --root-dir PATH                Default: /data
  --data-dir PATH                Default: <root-dir>/<chain>/<network>
  --keys-dir PATH                Keystore and Deposit Data directory
  --password-file PATH           Keystore and Prysm wallet password
  --public-ip ADDRESS            Override Genesis node public IPv4 detection
  --docker                       Deploy containers; default
  --binary                       Deploy downloaded native binaries
  --yes                          Confirm key generation in non-interactive runs
  -h, --help                     Show this help
  --version                      Show script version

Operations:
  --status                       Show services and synchronization state
  --logs [geth|beacon|validator] Follow logs
  --stop                         Stop this node
  --restart                      Restart this node
  --import-keys                  Import keys and restart the Validator Client

Examples:
  ./ab-pos.sh testnet prysm geth

  ./ab-pos.sh abapp1 testnet prysm geth

  ./ab-pos.sh testnet --status

  ./ab-pos.sh testnet prysm geth \
    --genesis --validator \
    --fee-recipient 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332

  ./ab-pos.sh testnet lighthouse geth \
    --generate-keys --validator \
    --amount 32000 \
    --withdrawal-address 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332 \
    --fee-recipient 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332
USAGE
}

function require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

function require_explicit_image_tag() {
    local image="$1"
    local label="$2"

    [[ "${image}" =~ ^[^[:space:]@]+:[^[:space:]@]+$ \
        && "${image}" != *:latest && "${image}" != *:stable ]] \
        || fail "${label} must use an explicit version tag: ${image:-empty}"
}

function require_release_version() {
    local version="$1"
    local label="$2"

    [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
        || fail "${label} must be an explicit Release version: ${version:-empty}"
}

function interactive_terminal_available() {
    [[ -t 1 && -r /dev/tty && -w /dev/tty ]]
}

function prompt_required_value() {
    local variable_name="$1"
    local prompt="$2"
    local option_name="$3"
    local value

    interactive_terminal_available \
        || fail "${option_name} is required in a non-interactive environment."
    while true; do
        printf '%s: ' "${prompt}" >/dev/tty
        IFS= read -r value </dev/tty \
            || fail "Unable to read ${prompt}."
        if [[ -n "${value}" ]]; then
            printf -v "${variable_name}" '%s' "${value}"
            return 0
        fi
        printf 'A value is required.\n' >/dev/tty
    done
}

function require_validator_count() {
    local value="$1"

    [[ "${value}" =~ ^[1-9][0-9]*$ ]] \
        || fail "Validator count must be a positive integer."
    [[ "${#value}" -lt 16 \
        || ( "${#value}" -eq 16 && "${value}" < "9007199254740992" ) ]] \
        || fail "Validator count is too large."
}

function is_address() {
    [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ \
        && "${1,,}" != "0x0000000000000000000000000000000000000000" ]]
}

function prompt_address() {
    local variable_name="$1"
    local prompt="$2"
    local option_name="$3"
    local default_value="${4:-}"
    local value

    interactive_terminal_available \
        || fail "${option_name} is required in a non-interactive environment."
    while true; do
        if [[ -n "${default_value}" ]]; then
            printf '%s [%s]: ' "${prompt}" "${default_value}" >/dev/tty
        else
            printf '%s: ' "${prompt}" >/dev/tty
        fi
        IFS= read -r value </dev/tty \
            || fail "Unable to read ${prompt}."
        value="${value:-${default_value}}"
        if is_address "${value}"; then
            printf -v "${variable_name}" '%s' "${value}"
            return 0
        fi
        printf 'Enter a non-zero, 0x-prefixed 20-byte address.\n' >/dev/tty
    done
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

formatted_amount=""
function format_gwei_amount() {
    local value="$1"
    local whole=$((value / gwei_per_token))
    local fraction

    printf -v fraction '%09d' "$((value % gwei_per_token))"
    while [[ "${fraction}" == *0 ]]; do
        fraction="${fraction%0}"
    done
    formatted_amount="${whole}"
    [[ -z "${fraction}" ]] || formatted_amount+=".${fraction}"
}

function validate_key_generation_amount() {
    local amount_gwei
    local amount_multiplier
    local amount_divisor
    local cli_amount_gwei
    local minimum_gwei

    parse_whole_token_amount_to_gwei "--amount" "${validator_deposit_amount}"
    amount_gwei="${parsed_gwei}"
    amount_multiplier="$(jq -r '.multiplier' "${active_deposit_settings_file}")"
    amount_divisor="$(jq -r '.divisor' "${active_deposit_settings_file}")"
    (( amount_gwei % amount_divisor == 0 )) \
        || fail "--amount cannot be represented exactly with the published Deposit conversion."
    cli_amount_gwei=$((amount_gwei / amount_divisor))
    (( cli_amount_gwei <= max_exact_integer / amount_multiplier )) \
        || fail "--amount is too large after applying the published Deposit conversion."
    parse_whole_token_amount_to_gwei \
        "Published minimum activation amount" \
        "$(jq -r '.min_activation_amount' "${active_deposit_settings_file}")"
    minimum_gwei="${parsed_gwei}"
    (( amount_gwei >= minimum_gwei )) \
        || fail "--amount must be at least $(jq -r '.min_activation_amount' "${active_deposit_settings_file}")."
}

function confirm_validator_key_generation() {
    local answer
    local total_deposit_amount

    (( validator_count <= max_exact_integer / validator_deposit_amount )) \
        || fail "Validator count and --amount produce a total that is too large."
    total_deposit_amount=$((validator_count * validator_deposit_amount))

    printf '\nValidator key generation summary:\n'
    printf '  Validator count:      %s\n' "${validator_count}"
    printf '  Start index:          %s\n' "${validator_start_index}"
    printf '  Amount per validator: %s native tokens\n' "${validator_deposit_amount}"
    printf '  Total Deposit amount: %s native tokens\n' "${total_deposit_amount}"
    printf '  Withdrawal address:   %s\n' "${withdrawal_address}"
    printf '  Mnemonic file:        %s\n' "${mnemonic_file}"

    if [[ "${assume_yes}" == true ]]; then
        return 0
    fi
    interactive_terminal_available \
        || fail "Non-interactive key generation requires --yes after reviewing the requested values."
    printf '\nGenerate this validator batch? [y/N]: ' >/dev/tty
    IFS= read -r answer </dev/tty \
        || fail "Unable to read key generation confirmation."
    case "${answer,,}" in
        y | yes) ;;
        *)
            color "33" "Validator key generation cancelled."
            exit 0
            ;;
    esac
}

function install_missing_dependencies() {
    local command_name
    local needs_coreutils=false
    local -a packages=()

    for command_name in curl find jq openssl tar; do
        if command -v "${command_name}" >/dev/null 2>&1; then
            continue
        fi
        case "${command_name}" in
            curl) packages+=(curl) ;;
            find) packages+=(findutils) ;;
            jq) packages+=(jq) ;;
            openssl) packages+=(openssl) ;;
            tar) packages+=(tar) ;;
        esac
    done

    if [[ "${genesis_mode}" == true && "${key_generation_only:-false}" == false \
        && -z "${public_ip_override}" ]] \
        && ! command -v dig >/dev/null 2>&1; then
        packages+=(dnsutils)
    fi

    for command_name in install sha256sum; do
        command -v "${command_name}" >/dev/null 2>&1 || needs_coreutils=true
    done
    [[ "${needs_coreutils}" == false ]] || packages+=(coreutils)

    if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        packages+=(ca-certificates)
    fi

    if [[ "${deployment_mode}" == "docker" ]]; then
        command -v docker >/dev/null 2>&1 || packages+=(docker.io)
    elif [[ "${key_generation_only:-false}" == false ]]; then
        command -v setsid >/dev/null 2>&1 || packages+=(util-linux)
    fi

    if (( ${#packages[@]} == 0 )); then
        return 0
    fi
    [[ "$(uname -s)" == "Linux" ]] || fail "Automatic dependency installation supports Linux only."
    command -v apt-get >/dev/null 2>&1 \
        || fail "Missing dependencies: ${packages[*]}. Install them and run the command again."
    (( EUID == 0 )) \
        || fail "Missing dependencies: ${packages[*]}. Run the installer with sudo."

    color "34" "Installing required packages: ${packages[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

function ensure_docker_available() {
    docker info >/dev/null 2>&1 && return

    if (( EUID == 0 )); then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable --now docker >/dev/null 2>&1 || true
        elif command -v service >/dev/null 2>&1; then
            service docker start >/dev/null 2>&1 || true
        fi
    fi

    docker info >/dev/null 2>&1 \
        || fail "Docker is unavailable or permission was denied."
}

function require_address() {
    local name="$1"
    local value="$2"

    [[ "${value}" =~ ^0x[0-9a-fA-F]{40}$ ]] \
        || fail "Invalid ${name}: ${value}"
    [[ "${value,,}" != "0x0000000000000000000000000000000000000000" ]] \
        || fail "${name} must not be the zero address."
}

function is_ipv4_address() {
    local address="$1"
    local first
    local second
    local third
    local fourth

    [[ "${address}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r first second third fourth <<<"${address}"
    (( 10#${first} <= 255 && 10#${second} <= 255 \
        && 10#${third} <= 255 && 10#${fourth} <= 255 ))
}

function require_ipv4_address() {
    local name="$1"
    local address="$2"

    is_ipv4_address "${address}" || fail "Invalid ${name}: ${address}"
}

function prompt_ipv4_address() {
    local variable_name="$1"
    local prompt="$2"
    local option_name="$3"
    local value

    interactive_terminal_available \
        || fail "${option_name} is required in a non-interactive environment."
    while true; do
        printf '%s: ' "${prompt}" >/dev/tty
        IFS= read -r value </dev/tty \
            || fail "Unable to read ${prompt}."
        if is_ipv4_address "${value}"; then
            printf -v "${variable_name}" '%s' "${value}"
            return 0
        fi
        printf 'Enter a valid IPv4 address.\n' >/dev/tty
    done
}

function detect_public_ipv4() {
    local address

    while IFS= read -r address; do
        address="${address//[[:space:]]/}"
        if [[ "${address}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            printf '%s\n' "${address}"
            return 0
        fi
    done < <(dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null)
    return 1
}

function first_data_line() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${file}" | head -n 1
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

chain_name=""
network=""
consensus_client=""
execution_client=""
genesis_mode=false
validator_mode=false
generate_keys=false
generated_unique_validator_keys=0
import_keys=false
archive_mode=false
operation="install"
log_service=""
withdrawal_address=""
fee_recipient=""
extra_data=""
graffiti=""
extra_data_selected=false
graffiti_selected=false
checkpoint_url=""
release_version="latest"
release_repo="${default_release_repo}"
release_url=""
network_release_url=""
geth_asset_name=""
geth_asset_url=""
geth_checksum_url=""
resolved_geth_version=""
lighthouse_asset_name=""
lighthouse_asset_url=""
lighthouse_checksum_url=""
resolved_lighthouse_version=""
geth_image=""
platform_arch=""
deployment_mode="docker"
deployment_mode_selected=false
root_dir="${default_root_dir}"
data_dir=""
keys_dir=""
password_file=""
password_file_selected=false
mnemonic_file=""
deposit_settings_file=""
validator_count=""
validator_start_index="0"
validator_deposit_amount="${VALIDATOR_DEPOSIT_AMOUNT:-}"
assume_yes=false
public_ip_override=""
node_public_ip=""
default_prysm_beacon_image=""
default_prysm_validator_image=""
default_lighthouse_image=""
deposit_cli_image=""
prysm_release_version=""
ab_lighthouse_version=""
deposit_cli_release_version=""

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--version" ]]; then
    printf '%s\n' "${script_version}"
    exit 0
fi

[[ "$#" -ge 1 ]] || {
    usage >&2
    exit 1
}

chain_name="${default_chain_name,,}"
target="${1,,}"
shift

case "${target}" in
    test | testnet | main | mainnet)
        network="${target}"
        ;;
    *)
        chain_name="${target}"
        [[ -n "${1:-}" && "${1:-}" != --* ]] \
            || fail "Network is required after chain: ${chain_name}"
        network="${1,,}"
        shift
        ;;
esac

if [[ -n "${1:-}" && "${1:-}" != --* ]]; then
    case "${1,,}" in
        prysm | lighthouse)
            consensus_client="${1,,}"
            shift
            ;;
        geth)
            execution_client="geth"
            shift
            ;;
        *) fail "Unsupported consensus client: $1" ;;
    esac
fi

if [[ -n "${1:-}" && "${1:-}" != --* ]]; then
    execution_client="${1,,}"
    shift
fi

case "${network}" in
    test | testnet) network="testnet" ;;
    main | mainnet) network="mainnet" ;;
    *) fail "Unsupported network: ${network}" ;;
esac

[[ "${chain_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "Invalid chain name: ${chain_name}"

execution_client="${execution_client:-geth}"
[[ "${execution_client}" == "geth" ]] || fail "Unsupported execution client: ${execution_client}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --genesis) genesis_mode=true ;;
        --validator) validator_mode=true ;;
        --generate-keys) generate_keys=true ;;
        --import-keys) import_keys=true; operation="import-keys" ;;
        --archive) archive_mode=true ;;
        --withdrawal-address) withdrawal_address="${2:-}"; shift ;;
        --fee-recipient) fee_recipient="${2:-}"; shift ;;
        --extra-data | --graffiti)
            [[ "$#" -ge 2 && "$2" != --* ]] \
                || fail "$1 requires text; use an empty quoted string to restore the client default."
            if [[ "$1" == --extra-data ]]; then
                extra_data="$2"
                extra_data_selected=true
            else
                graffiti="$2"
                graffiti_selected=true
            fi
            shift
            ;;
        --validator-count) validator_count="${2:-}"; shift ;;
        --validator-start-index) validator_start_index="${2:-}"; shift ;;
        --amount) validator_deposit_amount="${2:-}"; shift ;;
        --checkpoint-url) checkpoint_url="${2:-}"; shift ;;
        --release) release_version="${2:-}"; shift ;;
        --release-repo) release_repo="${2:-}"; shift ;;
        --release-url) release_url="${2:-}"; shift ;;
        --root-dir) root_dir="${2:-}"; shift ;;
        --data-dir) data_dir="${2:-}"; shift ;;
        --keys-dir) keys_dir="${2:-}"; shift ;;
        --password-file) password_file="${2:-}"; password_file_selected=true; shift ;;
        --mnemonic-file) mnemonic_file="${2:-}"; shift ;;
        --deposit-settings) deposit_settings_file="${2:-}"; shift ;;
        --public-ip) public_ip_override="${2:-}"; shift ;;
        --docker)
            [[ "${deployment_mode_selected}" == false || "${deployment_mode}" == "docker" ]] \
                || fail "--docker and --binary cannot be used together."
            deployment_mode="docker"
            deployment_mode_selected=true
            ;;
        --binary)
            [[ "${deployment_mode_selected}" == false || "${deployment_mode}" == "binary" ]] \
                || fail "--docker and --binary cannot be used together."
            deployment_mode="binary"
            deployment_mode_selected=true
            ;;
        --yes) assume_yes=true ;;
        --status) operation="status" ;;
        --stop) operation="stop" ;;
        --restart) operation="restart" ;;
        --logs)
            operation="logs"
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                log_service="$2"
                shift
            fi
            ;;
        -h | --help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift
done

if [[ -n "${validator_count}" ]]; then
    require_validator_count "${validator_count}"
fi
[[ "${validator_start_index}" =~ ^[0-9]+$ ]] || fail "Validator start index must be a non-negative integer."
[[ "${release_repo}" =~ ^[^/]+/[^/]+$ ]] || fail "Release repository must use OWNER/REPO format."

[[ "${import_keys}" == false || "${generate_keys}" == false ]] \
    || fail "--generate-keys and --import-keys cannot be used together."
[[ "${import_keys}" == false || "${validator_mode}" == false ]] \
    || fail "--import-keys already targets the installed Validator Client; do not add --validator."
key_generation_only=false
if [[ "${generate_keys}" == true && "${validator_mode}" == false ]]; then
    key_generation_only=true
fi
[[ "${generate_keys}" == false || "${operation}" == install ]] \
    || fail "--generate-keys cannot be combined with a node operation."
if [[ -n "${deposit_settings_file}" && "${key_generation_only}" == false ]]; then
    fail "--deposit-settings is supported only with key-only --generate-keys."
fi
data_dir="${data_dir:-${root_dir}/${chain_name}/${network}}"

function validate_block_text() {
    local option="$1"
    local value="$2"
    local LC_ALL=C

    (( ${#value} <= 32 )) \
        || fail "${option} must be at most 32 UTF-8 bytes (received ${#value})."
    [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] \
        || fail "${option} must be a single line of text."
}

validate_block_text --extra-data "${extra_data}"
validate_block_text --graffiti "${graffiti}"
if [[ "${extra_data_selected}" == true || "${graffiti_selected}" == true ]]; then
    [[ "${operation}" == install && "${key_generation_only}" == false ]] \
        || fail "--extra-data and --graffiti require a node installation run, not a node operation or key-only generation."
fi
[[ "${graffiti_selected}" == false || "${validator_mode}" == true ]] \
    || fail "--graffiti requires --validator."

function detect_docker_consensus_client() {
    command -v docker >/dev/null 2>&1 || return 1

    local container_id
    local container_name
    local label_client
    local label_chain
    local label_network
    local label_role
    local description
    local mounts
    local relevant
    local -A detected=()

    while IFS= read -r container_id; do
        [[ -n "${container_id}" ]] || continue
        container_name="$(docker container inspect "${container_id}" --format '{{.Name}}' 2>/dev/null)" || continue
        container_name="${container_name#/}"
        label_chain="$(docker container inspect "${container_id}" \
            --format '{{index .Config.Labels "io.abpos.chain"}}' 2>/dev/null || true)"
        label_network="$(docker container inspect "${container_id}" \
            --format '{{index .Config.Labels "io.abpos.network"}}' 2>/dev/null || true)"
        label_role="$(docker container inspect "${container_id}" \
            --format '{{index .Config.Labels "io.abpos.role"}}' 2>/dev/null || true)"
        label_client="$(docker container inspect "${container_id}" \
            --format '{{index .Config.Labels "io.abpos.consensus-client"}}' 2>/dev/null || true)"
        mounts="$(docker container inspect "${container_id}" \
            --format '{{range .Mounts}}{{println .Source}}{{end}}' 2>/dev/null || true)"

        relevant=false
        if [[ "${label_chain}:${label_network}:${label_role}" \
            == "${chain_name}:${network}:consensus" ]]; then
            relevant=true
        fi
        case "${container_name}" in
            "${chain_name}-${network}-consensus")
                relevant=true
                ;;
        esac
        if grep -Fxq -- "${data_dir}/prysm" <<<"${mounts}" \
            || grep -Fxq -- "${data_dir}/lighthouse" <<<"${mounts}"; then
            relevant=true
        fi
        [[ "${relevant}" == true ]] || continue

        case "${label_client}" in
            prysm | lighthouse)
                detected["${label_client}"]=1
                continue
                ;;
        esac

        description="$(docker container inspect "${container_id}" \
            --format '{{.Config.Image}} {{.Path}} {{range .Args}}{{.}} {{end}}' 2>/dev/null || true)"
        if [[ "${description,,}" == *prysm* ]] \
            || grep -Fxq -- "${data_dir}/prysm" <<<"${mounts}"; then
            detected[prysm]=1
        fi
        if [[ "${description,,}" == *lighthouse* ]] \
            || grep -Fxq -- "${data_dir}/lighthouse" <<<"${mounts}"; then
            detected[lighthouse]=1
        fi
    done < <(docker container ls -aq 2>/dev/null)

    if (( ${#detected[@]} == 1 )); then
        printf '%s\n' "${!detected[@]}"
        return 0
    fi
    (( ${#detected[@]} == 0 )) && return 1
    return 2
}

function detect_binary_consensus_client() {
    local launcher="${data_dir}/run/beacon.sh"
    local -A detected=()

    if [[ -f "${launcher}" ]]; then
        grep -qi prysm "${launcher}" && detected[prysm]=1
        grep -qi lighthouse "${launcher}" && detected[lighthouse]=1
    fi
    if (( ${#detected[@]} == 0 )); then
        [[ -d "${data_dir}/prysm" ]] && detected[prysm]=1
        [[ -d "${data_dir}/lighthouse" ]] && detected[lighthouse]=1
    fi
    if (( ${#detected[@]} == 1 )); then
        printf '%s\n' "${!detected[@]}"
        return 0
    fi
    (( ${#detected[@]} == 0 )) && return 1
    return 2
}

function detect_installed_consensus_client() {
    if [[ "${deployment_mode}" == "binary" ]]; then
        detect_binary_consensus_client
    else
        detect_docker_consensus_client
    fi
}

function select_consensus_client() {
    local selection

    [[ -t 1 && -r /dev/tty && -w /dev/tty ]] \
        || fail "Consensus client is required for a non-interactive installation. Specify prysm or lighthouse."
    printf '\nSelect a consensus client:\n  1) Prysm\n  2) Lighthouse\nSelection [1]: ' >/dev/tty
    IFS= read -r selection </dev/tty \
        || fail "Unable to read the consensus client selection."
    case "${selection,,}" in
        "" | 1 | prysm) printf '%s\n' prysm ;;
        2 | lighthouse) printf '%s\n' lighthouse ;;
        *) fail "Invalid consensus client selection: ${selection}" ;;
    esac
}

if [[ -z "${consensus_client}" && "${key_generation_only}" == false ]]; then
    detected_consensus_client=""
    detection_status=0
    detected_consensus_client="$(detect_installed_consensus_client)" || detection_status=$?
    case "${detection_status}" in
        0)
            consensus_client="${detected_consensus_client}"
            color "34" "Detected installed consensus client: ${consensus_client}"
            ;;
        1)
            if [[ "${operation}" == "install" ]]; then
                consensus_client="$(select_consensus_client)"
            else
                fail "Unable to detect the installed consensus client. Specify prysm or lighthouse."
            fi
            ;;
        *) fail "Multiple installed consensus clients were detected. Specify prysm or lighthouse." ;;
    esac
fi

if [[ "${key_generation_only}" == false ]]; then
    case "${consensus_client}" in
        prysm | lighthouse) ;;
        *) fail "Unsupported consensus client: ${consensus_client}" ;;
    esac
fi

keys_dir="${keys_dir:-${data_dir}/keys/validator_keys}"
password_file="${password_file:-$(dirname "${keys_dir}")/pwd.txt}"
share_dir="${data_dir}/share"
geth_data_dir="${data_dir}/geth"
beacon_data_dir="${data_dir}/${consensus_client:-consensus}"
validator_data_dir="${data_dir}/${consensus_client:-consensus}-validator"
mnemonic_file="${mnemonic_file:-$(dirname "${keys_dir}")/mnemonic.txt}"
config_dir="${data_dir}/config"
geth_config_dir="${config_dir}/execution/geth"
consensus_config_dir="${config_dir}/consensus"
prysm_config_dir="${consensus_config_dir}/prysm"
lighthouse_config_dir="${consensus_config_dir}/lighthouse"
lighthouse_network_dir="${lighthouse_config_dir}/network"
geth_nodekey_file="${geth_config_dir}/nodekey"
prysm_p2p_key_file="${prysm_config_dir}/p2p.key"
jwt_secret_file="${config_dir}/jwtsecret"
bin_dir="${data_dir}/bin"
run_dir="${data_dir}/run"
log_dir="${data_dir}/logs"
fee_recipient_file="${data_dir}/fee-recipient.txt"
validator_password_reference_file="${data_dir}/validator-password-file.txt"

container_prefix="${chain_name}-${network}"
geth_container="${container_prefix}-execution"
beacon_container="${container_prefix}-consensus"
validator_container="${container_prefix}-validator"

function container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

function container_mounts_host_path() {
    local container_name="$1"
    local host_path="$2"

    docker container inspect "${container_name}" \
        --format '{{range .Mounts}}{{println .Source}}{{end}}' 2>/dev/null \
        | grep -Fx -- "${host_path}" >/dev/null
}

function containers_for_role() {
    local role="$1"
    shift
    local container_id
    local container_name
    local host_path
    local matched
    local -A emitted=()

    while IFS= read -r container_id; do
        [[ -n "${container_id}" ]] || continue
        matched=false
        if [[ "$(docker container inspect "${container_id}" \
            --format '{{index .Config.Labels "io.abpos.chain"}}:{{index .Config.Labels "io.abpos.network"}}:{{index .Config.Labels "io.abpos.role"}}' 2>/dev/null)" \
            == "${chain_name}:${network}:${role}" ]]; then
            matched=true
        else
            for host_path in "$@"; do
                if container_mounts_host_path "${container_id}" "${host_path}"; then
                    matched=true
                    break
                fi
            done
        fi
        [[ "${matched}" == true ]] || continue
        container_name="$(docker container inspect "${container_id}" --format '{{.Name}}' 2>/dev/null)"
        container_name="${container_name#/}"
        if [[ -n "${container_name}" && -z "${emitted[${container_name}]:-}" ]]; then
            printf '%s\n' "${container_name}"
            emitted["${container_name}"]=1
        fi
    done < <(docker container ls -aq)
}

function replace_role_containers() {
    local role="$1"
    shift
    local container_name
    local stop_timeout=30

    [[ "${role}" != execution ]] || stop_timeout=120

    while IFS= read -r container_name; do
        [[ -n "${container_name}" ]] || continue
        color "34" "Replacing ${role} container ${container_name}."
        if [[ "$(docker container inspect "${container_name}" --format '{{.State.Running}}')" == true ]]; then
            docker stop --time "${stop_timeout}" "${container_name}" >/dev/null
        fi
        docker rm "${container_name}" >/dev/null
    done < <(containers_for_role "${role}" "$@")
}

function existing_role_container() {
    local preferred_name="$1"
    local role="$2"
    shift 2
    local container_name

    if container_exists "${preferred_name}"; then
        printf '%s\n' "${preferred_name}"
        return 0
    fi
    while IFS= read -r container_name; do
        [[ -n "${container_name}" ]] || continue
        printf '%s\n' "${container_name}"
        return 0
    done < <(containers_for_role "${role}" "$@")
}

function existing_validator_container() {
    [[ "${deployment_mode}" == "docker" ]] || return 0
    existing_role_container "${validator_container}" validator \
        "${data_dir}/prysm-validator" "${data_dir}/lighthouse-validator"
}

function validator_keys_are_imported() {
    case "${consensus_client}" in
        prysm)
            [[ -s "${validator_data_dir}/direct/accounts/all-accounts.keystore.json" ]]
            ;;
        lighthouse)
            [[ -n "$(find "${validator_data_dir}/validators" -type f -name voting-keystore.json -print -quit 2>/dev/null)" ]]
            ;;
    esac
}

function validator_key_import_required() {
    if ! validator_keys_are_imported; then
        return 0
    fi
    [[ "${generate_keys}" == true && "${generated_unique_validator_keys}" -gt 0 ]]
}

function save_local_setting() {
    local destination="$1"
    local value="$2"
    local mode="$3"
    local temporary_file

    temporary_file="$(mktemp "${data_dir}/.$(basename "${destination}").XXXXXX")"
    printf '%s\n' "${value}" >"${temporary_file}"
    chmod "${mode}" "${temporary_file}"
    mv -f -- "${temporary_file}" "${destination}"
}

function fee_recipient_from_existing_runtime() {
    local container_name
    local launcher

    if [[ "${deployment_mode}" == "docker" ]]; then
        container_name="$(existing_validator_container)"
        [[ -n "${container_name}" ]] || return 0
        docker container inspect "${container_name}" --format '{{json .Config.Cmd}}' \
            | jq -r '.[]? | select(startswith("--suggested-fee-recipient=")) | sub("^--suggested-fee-recipient="; "")' \
            | head -n 1
        return 0
    fi

    launcher="$(binary_launcher_file validator)"
    [[ -f "${launcher}" ]] || return 0
    grep -oE -- '--suggested-fee-recipient=0x[0-9a-fA-F]{40}' "${launcher}" \
        | head -n 1 \
        | cut -d= -f2
}

function resolve_saved_block_metadata() {
    local setting option setting_file selected
    for setting in extra_data graffiti; do
        [[ "${setting}" != graffiti || "${validator_mode}" == true ]] || continue
        local -n value="${setting}"
        selected="${setting}_selected"
        option="${setting//_/-}"
        setting_file="${config_dir}/${option}.txt"
        if [[ "${!selected}" == false && -f "${setting_file}" ]]; then
            value="$(<"${setting_file}")"
        fi
        validate_block_text "--${option}" "${value}"
        if [[ "${!selected}" == true ]]; then
            save_local_setting "${setting_file}" "${value}" 0644
        fi
    done

    geth_metadata_args=()
    validator_metadata_args=()
    if [[ -n "${extra_data}" ]]; then
        geth_metadata_args+=("--miner.extradata=${extra_data}")
    fi
    if [[ "${validator_mode}" == true && -n "${graffiti}" ]]; then
        if [[ "${consensus_client}" == prysm ]]; then
            # Prysm interprets "hex:" specially; encode to preserve all literal text.
            require_command od
            validator_metadata_args+=("--graffiti=hex:$(printf '%s' "${graffiti}" | od -An -v -tx1 | tr -d ' \n')")
        else
            validator_metadata_args+=("--graffiti=${graffiti}")
        fi
    fi
}

function password_file_from_existing_container() {
    local container_name

    [[ "${deployment_mode}" == "docker" ]] || return 0
    container_name="$(existing_validator_container)"
    [[ -n "${container_name}" ]] || return 0
    docker container inspect "${container_name}" --format '{{json .Mounts}}' \
        | jq -r '.[]? | select(.Destination == "/password.txt") | .Source' \
        | head -n 1
}

function resolve_saved_validator_settings() {
    local detected_value

    mkdir -p "${data_dir}"

    if [[ -z "${fee_recipient}" ]]; then
        fee_recipient="$(first_data_line "${fee_recipient_file}")"
    fi
    if [[ -z "${fee_recipient}" ]]; then
        detected_value="$(fee_recipient_from_existing_runtime)"
        fee_recipient="${detected_value}"
    fi
    if [[ -z "${fee_recipient}" ]]; then
        prompt_address \
            fee_recipient \
            "Validator fee recipient" \
            "--fee-recipient" \
            "${withdrawal_address}"
    fi
    require_address "fee recipient" "${fee_recipient}"
    save_local_setting "${fee_recipient_file}" "${fee_recipient}" 0644

    resolve_validator_password_file
}

function resolve_validator_password_file() {
    local detected_value
    local saved_value

    if [[ "${password_file_selected}" == false && ! -s "${password_file}" ]]; then
        saved_value="$(first_data_line "${validator_password_reference_file}")"
        if [[ -n "${saved_value}" && -s "${saved_value}" ]]; then
            password_file="${saved_value}"
        else
            detected_value="$(password_file_from_existing_container)"
            if [[ -n "${detected_value}" && -s "${detected_value}" ]]; then
                password_file="${detected_value}"
            fi
        fi
    fi
}

function save_validator_password_reference() {
    [[ "${consensus_client}" == "prysm" && -s "${password_file}" ]] || return 0
    save_local_setting "${validator_password_reference_file}" "${password_file}" 0600
}

function prysm_import_was_duplicate_only() {
    local import_log="$1"
    local duplicate_count
    local source_count

    source_count="$(find "${keys_dir}" -maxdepth 1 -type f -name 'keystore-*.json' | wc -l | tr -d ' ')"
    duplicate_count="$(grep -c 'Duplicate key .* found in import request, skipped' "${import_log}" || true)"
    [[ "${source_count}" -gt 0 \
        && "${duplicate_count}" -eq "${source_count}" \
        && -n "$(grep -F 'no accounts were successfully imported' "${import_log}" || true)" ]]
}

function execution_api_ready() {
    local response

    response="$(curl -fsS --max-time 2 \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://127.0.0.1:8545 2>/dev/null)" || return 1
    jq -e '.result | type == "string" and test("^0x[0-9a-fA-F]+$")' \
        <<<"${response}" >/dev/null 2>&1
}

function consensus_api_ready() {
    curl -fsS --max-time 2 \
        http://127.0.0.1:3500/eth/v1/node/syncing 2>/dev/null \
        | jq -e '.data | type == "object"' >/dev/null 2>&1
}

function wait_for_node_apis() {
    local deadline=$((SECONDS + 30))
    local execution_ready=false
    local consensus_ready=false
    local waiting_message_shown=false

    while true; do
        if [[ "${execution_ready}" == false ]] && execution_api_ready; then
            execution_ready=true
        fi
        if [[ "${consensus_ready}" == false ]] && consensus_api_ready; then
            consensus_ready=true
        fi
        if [[ "${execution_ready}" == true && "${consensus_ready}" == true ]]; then
            return 0
        fi
        (( SECONDS < deadline )) || return 1
        if [[ "${waiting_message_shown}" == false ]]; then
            printf '\nWaiting for node APIs.\n'
            waiting_message_shown=true
        fi
        sleep 2
    done
}

function show_execution_status() {
    local block_response
    local peer_response
    local sync_response
    local block_hex
    local peer_hex
    local sync_value

    block_response="$(curl -fsS --max-time 5 \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://127.0.0.1:8545 2>/dev/null)" || block_response=""
    peer_response="$(curl -fsS --max-time 5 \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":2}' \
        http://127.0.0.1:8545 2>/dev/null)" || peer_response=""
    sync_response="$(curl -fsS --max-time 5 \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":3}' \
        http://127.0.0.1:8545 2>/dev/null)" || sync_response=""

    block_hex="$(jq -er '.result | select(type == "string")' <<<"${block_response}" 2>/dev/null)" \
        || block_hex=""
    peer_hex="$(jq -er '.result | select(type == "string")' <<<"${peer_response}" 2>/dev/null)" \
        || peer_hex=""
    sync_value="$(jq -cr 'if has("result") then .result else empty end' \
        <<<"${sync_response}" 2>/dev/null)" || sync_value=""

    printf '\nExecution:\n'
    if [[ ! "${block_hex}" =~ ^0x[0-9a-fA-F]+$ \
        || ! "${peer_hex}" =~ ^0x[0-9a-fA-F]+$ \
        || -z "${sync_value}" ]]; then
        printf '  Status: not ready\n'
        return
    fi
    printf '  Block: %d\n' "$((block_hex))"
    printf '  Peers: %d\n' "$((peer_hex))"
    if [[ "${sync_value}" == false ]]; then
        printf '  Syncing: false\n'
    else
        printf '  Syncing: true\n'
    fi
}

function show_consensus_status() {
    local sync_response
    local peer_response
    local finality_response
    local head_slot
    local sync_distance
    local is_syncing
    local is_optimistic
    local connected_peers
    local justified_epoch
    local finalized_epoch

    sync_response="$(curl -fsS --max-time 5 \
        http://127.0.0.1:3500/eth/v1/node/syncing 2>/dev/null)" || sync_response=""
    if ! jq -e '.data | type == "object"' <<<"${sync_response}" >/dev/null 2>&1; then
        printf '\nConsensus:\n'
        printf '  Status: not ready\n'
        return 1
    fi

    head_slot="$(jq -r '.data.head_slot // "unknown"' <<<"${sync_response}")"
    sync_distance="$(jq -r '.data.sync_distance // "unknown"' <<<"${sync_response}")"
    is_syncing="$(jq -r \
        'if (.data | has("is_syncing")) then .data.is_syncing else "unknown" end' \
        <<<"${sync_response}")"
    is_optimistic="$(jq -r \
        'if (.data | has("is_optimistic")) then .data.is_optimistic else "unknown" end' \
        <<<"${sync_response}")"

    printf '\nConsensus:\n'
    printf '  Head slot: %s\n' "${head_slot}"
    printf '  Sync distance: %s\n' "${sync_distance}"
    printf '  Syncing: %s\n' "${is_syncing}"
    printf '  Optimistic: %s\n' "${is_optimistic}"

    peer_response="$(curl -fsS --max-time 5 \
        http://127.0.0.1:3500/eth/v1/node/peer_count 2>/dev/null)" || peer_response=""
    connected_peers="$(jq -er '.data.connected' <<<"${peer_response}" 2>/dev/null)" \
        || connected_peers="unknown"
    printf '  Peers: %s\n' "${connected_peers}"

    finality_response="$(curl -fsS --max-time 5 \
        http://127.0.0.1:3500/eth/v1/beacon/states/head/finality_checkpoints 2>/dev/null)" \
        || finality_response=""
    justified_epoch="$(jq -er '.data.current_justified.epoch' <<<"${finality_response}" 2>/dev/null)" \
        || justified_epoch="unknown"
    finalized_epoch="$(jq -er '.data.finalized.epoch' <<<"${finality_response}" 2>/dev/null)" \
        || finalized_epoch="unknown"
    printf '  Justified epoch: %s\n' "${justified_epoch}"
    printf '  Finalized epoch: %s\n' "${finalized_epoch}"
}

function show_genesis_node_information() {
    local execution_response
    local consensus_response
    local execution_enode="not ready"
    local consensus_enr="not ready"
    local identity_deadline
    local waiting_message_shown=false

    [[ "${genesis_mode}" == true ]] || return 0
    identity_deadline=$((SECONDS + 30))

    while true; do
        if [[ "${execution_enode}" == "not ready" ]]; then
            execution_response="$(curl -fsS --max-time 2 \
                -H 'content-type: application/json' \
                --data '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' \
                http://127.0.0.1:8545 2>/dev/null)" || execution_response=""
            execution_enode="$(jq -er '.result.enode' <<<"${execution_response}" 2>/dev/null)" \
                || execution_enode="not ready"
        fi
        if [[ "${consensus_enr}" == "not ready" ]]; then
            consensus_response="$(curl -fsS --max-time 2 \
                http://127.0.0.1:3500/eth/v1/node/identity 2>/dev/null)" \
                || consensus_response=""
            consensus_enr="$(jq -er '.data.enr' <<<"${consensus_response}" 2>/dev/null)" \
                || consensus_enr="not ready"
        fi
        if [[ "${execution_enode}" != "not ready" && "${consensus_enr}" != "not ready" ]]; then
            break
        fi
        (( SECONDS < identity_deadline )) || break
        if [[ "${waiting_message_shown}" == false ]]; then
            printf '\nWaiting for Genesis node identity APIs.\n'
            waiting_message_shown=true
        fi
        sleep 2
    done

    printf '\nGenesis node information:\n'
    printf '  Public IP: %s\n' "${node_public_ip}"
    printf '  Execution enode: %s\n' "${execution_enode}"
    printf '  Consensus ENR: %s\n' "${consensus_enr}"
    if [[ "${execution_enode}" == "not ready" || "${consensus_enr}" == "not ready" ]]; then
        printf '  Identity APIs are not ready yet. Query them after the clients finish starting.\n'
    fi
}

function show_docker_service() {
    local service="$1"
    local container_name="$2"
    local image
    local status

    [[ -n "${container_name}" ]] || return 0
    image="$(docker container inspect "${container_name}" --format '{{.Config.Image}}')"
    status="$(docker container inspect "${container_name}" --format '{{.State.Status}}')"
    printf '%-12s %-30s %-45s %s\n' \
        "${service}" "${container_name}" "${image}" "${status}"
}

function show_docker_status() {
    local wait_for_api="${1:-false}"
    local execution_name
    local consensus_name
    local validator_name

    execution_name="$(existing_role_container "${geth_container}" execution "${geth_data_dir}")"
    consensus_name="$(existing_role_container "${beacon_container}" consensus \
        "${data_dir}/prysm" "${data_dir}/lighthouse")"
    validator_name="$(existing_role_container "${validator_container}" validator \
        "${data_dir}/prysm-validator" "${data_dir}/lighthouse-validator")"

    printf '\n%-12s %-30s %-45s %s\n' SERVICE CONTAINER IMAGE STATUS
    show_docker_service Execution "${execution_name}"
    show_docker_service Consensus "${consensus_name}"
    show_docker_service Validator "${validator_name}"
    if [[ "${wait_for_api}" == true ]]; then
        wait_for_node_apis || true
    fi
    show_execution_status
    show_consensus_status || true
}

function operate_existing_docker_node() {
    local runtime_geth_container
    local runtime_beacon_container
    local runtime_validator_container
    local -a runtime_containers=()

    runtime_geth_container="$(existing_role_container "${geth_container}" execution "${geth_data_dir}")"
    runtime_beacon_container="$(existing_role_container "${beacon_container}" consensus \
        "${data_dir}/prysm" "${data_dir}/lighthouse")"
    runtime_validator_container="$(existing_role_container "${validator_container}" validator \
        "${data_dir}/prysm-validator" "${data_dir}/lighthouse-validator")"

    case "${operation}" in
        status) show_docker_status ;;
        stop)
            [[ -z "${runtime_validator_container}" ]] || runtime_containers+=("${runtime_validator_container}")
            [[ -z "${runtime_beacon_container}" ]] || runtime_containers+=("${runtime_beacon_container}")
            [[ -z "${runtime_geth_container}" ]] || runtime_containers+=("${runtime_geth_container}")
            [[ "${#runtime_containers[@]}" -eq 0 ]] || docker stop "${runtime_containers[@]}"
            ;;
        restart)
            [[ -z "${runtime_geth_container}" ]] || runtime_containers+=("${runtime_geth_container}")
            [[ -z "${runtime_beacon_container}" ]] || runtime_containers+=("${runtime_beacon_container}")
            [[ -z "${runtime_validator_container}" ]] || runtime_containers+=("${runtime_validator_container}")
            [[ "${#runtime_containers[@]}" -eq 0 ]] || docker restart "${runtime_containers[@]}"
            ;;
        logs)
            case "${log_service:-beacon}" in
                geth)
                    [[ -n "${runtime_geth_container}" ]] || fail "Execution container was not found."
                    docker logs -f --tail 200 "${runtime_geth_container}"
                    ;;
                beacon | prysm | lighthouse)
                    [[ -n "${runtime_beacon_container}" ]] || fail "Consensus container was not found."
                    docker logs -f --tail 200 "${runtime_beacon_container}"
                    ;;
                validator)
                    [[ -n "${runtime_validator_container}" ]] || fail "Validator container was not found."
                    docker logs -f --tail 200 "${runtime_validator_container}"
                    ;;
                *) fail "Unknown log service: ${log_service}" ;;
            esac
            ;;
    esac
}

function binary_pid_file() {
    printf '%s/%s.pid\n' "${run_dir}" "$1"
}

function binary_launcher_file() {
    printf '%s/%s.sh\n' "${run_dir}" "$1"
}

function binary_log_file() {
    printf '%s/%s.log\n' "${log_dir}" "$1"
}

function binary_executable_file() {
    printf '%s/%s.binary\n' "${run_dir}" "$1"
}

function binary_service_running() {
    local pid_file
    local executable_file
    local expected_executable
    local process_argument
    local pid

    pid_file="$(binary_pid_file "$1")"
    executable_file="$(binary_executable_file "$1")"
    [[ -s "${pid_file}" && -s "${executable_file}" ]] || return 1
    pid="$(<"${pid_file}")"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "${pid}" 2>/dev/null || return 1
    expected_executable="$(<"${executable_file}")"
    while IFS= read -r -d '' process_argument; do
        [[ "${process_argument}" == "${expected_executable}" ]] && return 0
    done <"/proc/${pid}/cmdline"
    return 1
}

function show_binary_status() {
    local wait_for_api="${1:-false}"
    local service
    local service_label
    local pid_file
    local pid

    printf '%-12s %-8s %s\n' SERVICE PID STATUS
    for service in geth beacon validator; do
        case "${service}" in
            geth) service_label="Execution" ;;
            beacon) service_label="Consensus" ;;
            validator) service_label="Validator" ;;
        esac
        pid_file="$(binary_pid_file "${service}")"
        pid="-"
        [[ -s "${pid_file}" ]] && pid="$(<"${pid_file}")"
        if binary_service_running "${service}"; then
            printf '%-12s %-8s %s\n' "${service_label}" "${pid}" running
        elif [[ -x "$(binary_launcher_file "${service}")" ]]; then
            printf '%-12s %-8s %s\n' "${service_label}" "${pid}" stopped
        fi
    done
    if [[ "${wait_for_api}" == true ]]; then
        wait_for_node_apis || true
    fi
    show_execution_status
    show_consensus_status || true
}

function stop_binary_service() {
    local service="$1"
    local pid_file
    local pid
    local attempt

    pid_file="$(binary_pid_file "${service}")"
    if ! binary_service_running "${service}"; then
        rm -f -- "${pid_file}"
        return
    fi
    pid="$(<"${pid_file}")"
    kill "${pid}"
    for attempt in {1..20}; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill -KILL "${pid}"
    fi
    rm -f -- "${pid_file}"
}

function start_binary_service() {
    local service="$1"
    local launcher
    local log_file
    local pid_file
    local pid

    launcher="$(binary_launcher_file "${service}")"
    log_file="$(binary_log_file "${service}")"
    pid_file="$(binary_pid_file "${service}")"
    [[ -x "${launcher}" ]] || fail "Binary launcher is missing: ${launcher}"
    binary_service_running "${service}" && fail "${service} is already running."
    rm -f -- "${pid_file}"
    setsid "${launcher}" </dev/null >>"${log_file}" 2>&1 &
    pid=$!
    printf '%s\n' "${pid}" >"${pid_file}"
    sleep 1
    binary_service_running "${service}" \
        || fail "${service} exited during startup; inspect ${log_file}."
}

function operate_existing_binary_node() {
    local service

    mkdir -p "${run_dir}" "${log_dir}"
    case "${operation}" in
        status) show_binary_status ;;
        stop)
            for service in validator beacon geth; do
                stop_binary_service "${service}"
            done
            ;;
        restart)
            for service in validator beacon geth; do
                stop_binary_service "${service}"
            done
            for service in geth beacon validator; do
                [[ -x "$(binary_launcher_file "${service}")" ]] || continue
                start_binary_service "${service}"
            done
            show_binary_status
            ;;
        logs)
            case "${log_service:-beacon}" in
                geth) service="geth" ;;
                beacon | prysm | lighthouse) service="beacon" ;;
                validator) service="validator" ;;
                *) fail "Unknown log service: ${log_service}" ;;
            esac
            [[ -f "$(binary_log_file "${service}")" ]] \
                || fail "Log file does not exist: $(binary_log_file "${service}")"
            tail -n 200 -f "$(binary_log_file "${service}")"
            ;;
    esac
}

function import_keys_into_docker_validator() {
    local runtime_validator_container
    local validator_image
    local import_log
    local import_status=0

    runtime_validator_container="$(existing_validator_container)"
    [[ -n "${runtime_validator_container}" ]] \
        || fail "Validator container was not found. Install a Validator node before using --import-keys."
    validator_image="$(docker container inspect "${runtime_validator_container}" --format '{{.Config.Image}}')"
    [[ -n "$(find "${keys_dir}" -maxdepth 1 -type f -name 'keystore-*.json' -print -quit 2>/dev/null)" ]] \
        || fail "No validator keystores were found in ${keys_dir}."
    resolve_validator_password_file
    [[ -s "${password_file}" ]] || fail "Missing validator password file: ${password_file}"

    docker stop --time 30 "${runtime_validator_container}" >/dev/null
    import_log="$(mktemp "${data_dir}/validator-import.XXXXXX")"
    if [[ "${consensus_client}" == "prysm" ]]; then
        docker run --rm \
            -v "${validator_data_dir}:/wallet" \
            -v "${keys_dir}:/keys:ro" \
            -v "${password_file}:/password.txt:ro" \
            "${validator_image}" \
            accounts import --accept-terms-of-use=true \
            --wallet-dir=/wallet --wallet-password-file=/password.txt \
            --account-password-file=/password.txt --keys-dir=/keys \
            >"${import_log}" 2>&1 || import_status=$?
        cat "${import_log}"
        if (( import_status != 0 )) && prysm_import_was_duplicate_only "${import_log}"; then
            color "33" "All supplied Prysm validator keys were already imported."
            import_status=0
        fi
    else
        docker run --rm \
            -v "${validator_data_dir}:/validator-data" \
            -v "${share_dir}:/share:ro" \
            -v "${keys_dir}:/keys:ro" \
            -v "${password_file}:/password.txt:ro" \
            "${validator_image}" \
            lighthouse account validator import \
            --testnet-dir=/share --datadir=/validator-data \
            --directory=/keys --reuse-password --password-file=/password.txt \
            >"${import_log}" 2>&1 || import_status=$?
        cat "${import_log}"
    fi
    docker start "${runtime_validator_container}" >/dev/null
    rm -f -- "${import_log}"
    if (( import_status != 0 )); then
        fail "Validator key import failed; the existing Validator Client was restarted."
    fi
    color "32" "Validator keys imported. Restarted ${runtime_validator_container}."
}

function import_keys_into_binary_validator() {
    local import_log
    local import_status=0

    [[ -x "$(binary_launcher_file validator)" ]] \
        || fail "Validator launcher was not found. Install a binary Validator node before using --import-keys."
    [[ -n "$(find "${keys_dir}" -maxdepth 1 -type f -name 'keystore-*.json' -print -quit 2>/dev/null)" ]] \
        || fail "No validator keystores were found in ${keys_dir}."
    resolve_validator_password_file
    [[ -s "${password_file}" ]] || fail "Missing validator password file: ${password_file}"

    if [[ "${consensus_client}" == "prysm" ]]; then
        [[ -x "${bin_dir}/prysm-validator" ]] || fail "Prysm Validator binary is missing."
    else
        [[ -x "${bin_dir}/lighthouse" ]] || fail "Lighthouse binary is missing."
    fi

    stop_binary_service validator
    import_log="$(mktemp "${data_dir}/validator-import.XXXXXX")"
    if [[ "${consensus_client}" == "prysm" ]]; then
        "${bin_dir}/prysm-validator" accounts import --accept-terms-of-use=true \
            "--wallet-dir=${validator_data_dir}" "--wallet-password-file=${password_file}" \
            "--account-password-file=${password_file}" "--keys-dir=${keys_dir}" \
            >"${import_log}" 2>&1 || import_status=$?
        cat "${import_log}"
        if (( import_status != 0 )) && prysm_import_was_duplicate_only "${import_log}"; then
            color "33" "All supplied Prysm validator keys were already imported."
            import_status=0
        fi
    else
        "${bin_dir}/lighthouse" account validator import \
            "--testnet-dir=${share_dir}" "--datadir=${validator_data_dir}" \
            "--directory=${keys_dir}" --reuse-password "--password-file=${password_file}" \
            >"${import_log}" 2>&1 || import_status=$?
        cat "${import_log}"
    fi
    start_binary_service validator
    rm -f -- "${import_log}"
    if (( import_status != 0 )); then
        fail "Validator key import failed; the existing Validator Client was restarted."
    fi
    color "32" "Validator keys imported. Restarted the Validator Client."
}

if [[ "${operation}" != "install" ]]; then
    require_command jq
    if [[ "${deployment_mode}" == "docker" ]]; then
        require_command docker
        if [[ "${operation}" == "import-keys" ]]; then
            import_keys_into_docker_validator
        else
            require_command curl
            operate_existing_docker_node
        fi
    else
        require_command setsid
        if [[ "${operation}" == "import-keys" ]]; then
            import_keys_into_binary_validator
        else
            require_command curl
            operate_existing_binary_node
        fi
    fi
    exit 0
fi

install_missing_dependencies

require_command curl
require_command find
require_command jq
require_command openssl
require_command sha256sum
require_command tar

if [[ "${deployment_mode}" == "docker" ]]; then
    require_command docker
    ensure_docker_available
elif [[ "${key_generation_only}" == false ]]; then
    require_command setsid
fi

if [[ "${genesis_mode}" == true && "${key_generation_only}" == false ]]; then
    if [[ -n "${public_ip_override}" ]]; then
        node_public_ip="${public_ip_override}"
    else
        require_command dig
        if ! node_public_ip="$(detect_public_ipv4)"; then
            prompt_ipv4_address \
                node_public_ip \
                "Genesis node public IPv4 address" \
                "--public-ip"
        fi
    fi
    require_ipv4_address "public IPv4 address" "${node_public_ip}"
fi

if [[ "${generate_keys}" == true ]]; then
    if [[ -z "${withdrawal_address}" ]]; then
        prompt_address \
            withdrawal_address \
            "Withdrawal address" \
            "--withdrawal-address"
    fi
    require_address "withdrawal address" "${withdrawal_address}"
    if [[ -z "${validator_count}" ]]; then
        prompt_required_value \
            validator_count \
            "Number of validators" \
            "--validator-count"
    fi
    require_validator_count "${validator_count}"
fi

if [[ "${validator_mode}" == true ]]; then
    resolve_saved_validator_settings
fi

mkdir -p "${share_dir}"
if [[ "${deployment_mode}" == "binary" ]]; then
    mkdir -p "${bin_dir}"
fi
if [[ "${key_generation_only}" == false ]]; then
    mkdir -p "${geth_data_dir}" "${beacon_data_dir}" "${geth_config_dir}"
    if [[ "${deployment_mode}" == "binary" ]]; then
        mkdir -p "${run_dir}" "${log_dir}"
    fi
    case "${consensus_client}" in
        prysm) mkdir -p "${prysm_config_dir}" ;;
        lighthouse) mkdir -p "${lighthouse_network_dir}" ;;
    esac
fi

function ensure_local_jwt_secret() {
    local jwt
    local temporary_file

    if [[ ! -s "${jwt_secret_file}" ]]; then
        temporary_file="$(mktemp "${config_dir}/.jwtsecret.XXXXXX")"
        openssl rand -hex 32 >"${temporary_file}"
        chmod 600 "${temporary_file}"
        mv -f -- "${temporary_file}" "${jwt_secret_file}"
        color "32" "Generated local Engine API JWT secret: ${jwt_secret_file}"
    fi

    jwt="$(tr -d '[:space:]' < "${jwt_secret_file}")"
    [[ "${jwt}" =~ ^[0-9a-fA-F]{64}$ ]] \
        || fail "Local JWT secret must contain exactly 32 bytes encoded as 64 hexadecimal characters: ${jwt_secret_file}"
    chmod 600 "${jwt_secret_file}"
}

if [[ "${key_generation_only}" == false ]]; then
    ensure_local_jwt_secret
fi

function validate_p2p_private_key() {
    local key_file="$1"
    local description="$2"
    local key

    [[ -f "${key_file}" ]] || fail "Missing ${description}: ${key_file}"
    key="$(cat "${key_file}")"
    [[ "${key}" =~ ^[0-9a-fA-F]{64}$ && "$(wc -c < "${key_file}")" -eq 64 ]] \
        || fail "${description} must contain exactly 32 bytes encoded as 64 hexadecimal characters: ${key_file}"
    chmod 600 "${key_file}"
}

function validate_lighthouse_private_key() {
    local key_file="$1"
    local key_size

    [[ -f "${key_file}" ]] || fail "Missing Lighthouse P2P private key: ${key_file}"
    key_size="$(wc -c < "${key_file}")"
    if [[ "${key_size}" -eq 64 ]]; then
        grep -Eq '^[0-9a-fA-F]{64}$' "${key_file}" \
            || fail "Invalid Lighthouse P2P private key: ${key_file}"
    elif [[ "${key_size}" -ne 32 ]]; then
        fail "Invalid Lighthouse P2P private key: ${key_file}"
    fi
    chmod 600 "${key_file}"
}

function prepare_geth_nodekey() {
    if [[ -e "${geth_nodekey_file}" ]]; then
        validate_p2p_private_key "${geth_nodekey_file}" "Geth P2P private key"
        return 0
    fi
    [[ ! -d "${geth_data_dir}/geth/chaindata" ]] \
        || fail "Geth P2P private key is missing from ${geth_nodekey_file}; refusing to reuse an existing chain database with a new node identity."
}

function persist_generated_geth_nodekey() {
    local generated_key="${geth_data_dir}/geth/nodekey"

    if [[ ! -e "${geth_nodekey_file}" ]]; then
        [[ -s "${generated_key}" ]] \
            || fail "Geth did not generate its P2P private key during initialization: ${generated_key}"
        mv -- "${generated_key}" "${geth_nodekey_file}"
        color "32" "Stored the new Geth P2P private key in ${geth_nodekey_file}."
    fi
    validate_p2p_private_key "${geth_nodekey_file}" "Geth P2P private key"
}

function prepare_prysm_p2p_key() {
    if [[ -e "${prysm_p2p_key_file}" ]]; then
        validate_p2p_private_key "${prysm_p2p_key_file}" "Prysm P2P private key"
        return 0
    fi
    [[ ! -e "${beacon_data_dir}/network-keys" ]] \
        || fail "Prysm P2P private key is missing from ${prysm_p2p_key_file}; refusing to import an identity from the beacon data directory."
}

function persist_generated_prysm_p2p_key() {
    local attempt
    local generated_key="${beacon_data_dir}/network-keys"

    if [[ -s "${prysm_p2p_key_file}" ]]; then
        validate_p2p_private_key "${prysm_p2p_key_file}" "Prysm P2P private key"
        return 0
    fi
    for attempt in {1..15}; do
        if [[ -s "${generated_key}" ]]; then
            mv -- "${generated_key}" "${prysm_p2p_key_file}"
            validate_p2p_private_key "${prysm_p2p_key_file}" "Prysm P2P private key"
            color "32" "Stored the new Prysm P2P private key in ${prysm_p2p_key_file}."
            return 0
        fi
        sleep 1
    done
    fail "Prysm did not create its persistent P2P private key: ${beacon_data_dir}/network-keys"
}

function prepare_lighthouse_network_identity() {
    mkdir -p "${lighthouse_network_dir}"
    if [[ -e "${lighthouse_network_dir}/key" ]]; then
        validate_lighthouse_private_key "${lighthouse_network_dir}/key"
    fi
}

function persist_generated_lighthouse_network_identity() {
    local attempt

    for attempt in {1..15}; do
        if [[ -s "${lighthouse_network_dir}/key" ]]; then
            validate_lighthouse_private_key "${lighthouse_network_dir}/key"
            return 0
        fi
        sleep 1
    done
    fail "Lighthouse did not create its persistent P2P private key: ${lighthouse_network_dir}/key"
}

function resolve_release() {
    local api_url="${github_api_url%/}/repos/${release_repo}/releases"
    local release_json
    local release_owner
    local network_asset_count
    local geth_asset_count
    local geth_checksum_count
    case "$(uname -m)" in
        x86_64 | amd64) platform_arch="amd64" ;;
        aarch64 | arm64) platform_arch="arm64" ;;
        *) fail "Unsupported host architecture: $(uname -m)" ;;
    esac

    if [[ -n "${release_url}" ]]; then
        network_release_url="${release_url}"
        if [[ "${deployment_mode}" == "docker" ]]; then
            [[ -n "${geth_image_override}" ]] \
                || fail "--release-url requires GETH_DOCKER_IMAGE with an explicit version tag in Docker mode."
            geth_image="${geth_image_override}"
        else
            [[ -n "${geth_binary_url_override}" && -n "${geth_binary_checksum_url_override}" ]] \
                || fail "--release-url requires AB_GETH_BINARY_URL and AB_GETH_BINARY_SHA256_URL in binary mode."
            geth_asset_url="${geth_binary_url_override}"
            geth_checksum_url="${geth_binary_checksum_url_override}"
            if [[ "${consensus_client}" == lighthouse ]]; then
                [[ -n "${lighthouse_binary_url_override}" && -n "${lighthouse_binary_checksum_url_override}" ]] \
                    || fail "--release-url with Lighthouse in binary mode requires AB_LIGHTHOUSE_BINARY_URL and AB_LIGHTHOUSE_BINARY_SHA256_URL."
                lighthouse_asset_url="${lighthouse_binary_url_override}"
                lighthouse_checksum_url="${lighthouse_binary_checksum_url_override}"
            fi
        fi
        return
    fi

    if [[ "${release_version}" == "latest" ]]; then
        release_json="$(curl -fsSL "${api_url}/latest")" || fail "Unable to query the latest Release."
    else
        release_json="$(curl -fsSL "${api_url}/tags/${release_version}")" || fail "Unable to query Release ${release_version}."
    fi

    network_asset_count="$(
        jq -r --arg prefix "${chain_name}-${network}-" '
            [.assets[] | select(.name | startswith($prefix)) | select(.name | endswith(".tar.gz"))] | length
        ' <<<"${release_json}"
    )"
    [[ "${network_asset_count}" -eq 1 ]] \
        || fail "The selected Release must contain exactly one ${chain_name}/${network} network archive; found ${network_asset_count}."
    network_release_url="$(
        jq -r --arg prefix "${chain_name}-${network}-" '
            [.assets[] | select(.name | startswith($prefix)) | select(.name | endswith(".tar.gz"))][0].browser_download_url
        ' <<<"${release_json}"
    )"

    geth_asset_count="$(
        jq -r --arg arch "${platform_arch}" '
            [.assets[] | select(.name | test("^ab-geth-v[0-9]+\\.[0-9]+\\.[0-9]+-ab\\.[1-9][0-9]*-linux-" + $arch + "$"))] | length
        ' <<<"${release_json}"
    )"
    [[ "${geth_asset_count}" -eq 1 ]] \
        || fail "The selected Release must contain exactly one AB Geth linux-${platform_arch} binary; found ${geth_asset_count}."

    geth_asset_name="$(
        jq -r --arg arch "${platform_arch}" '
            [.assets[] | select(.name | test("^ab-geth-v[0-9]+\\.[0-9]+\\.[0-9]+-ab\\.[1-9][0-9]*-linux-" + $arch + "$"))][0].name
        ' <<<"${release_json}"
    )"
    geth_checksum_count="$(
        jq -r --arg name "${geth_asset_name}.sha256" '
            [.assets[] | select(.name == $name)] | length
        ' <<<"${release_json}"
    )"
    [[ "${geth_checksum_count}" -eq 1 ]] \
        || fail "The selected Release must contain ${geth_asset_name}.sha256."
    geth_asset_url="$(
        jq -r --arg name "${geth_asset_name}" \
            '[.assets[] | select(.name == $name)][0].browser_download_url' <<<"${release_json}"
    )"
    geth_checksum_url="$(
        jq -r --arg name "${geth_asset_name}.sha256" \
            '[.assets[] | select(.name == $name)][0].browser_download_url' <<<"${release_json}"
    )"
    resolved_geth_version="${geth_asset_name#ab-geth-}"
    resolved_geth_version="${resolved_geth_version%-linux-${platform_arch}}"
    [[ "${resolved_geth_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-ab\.[1-9][0-9]*$ ]] \
        || fail "Unable to parse the AB Geth version from ${geth_asset_name}."

    if [[ "${consensus_client}" == lighthouse ]]; then
        local lighthouse_asset_count
        lighthouse_asset_count="$(jq -r --arg arch "${platform_arch}" '
            [.assets[] | select(.name | test("^ab-lighthouse-v[0-9]+\\.[0-9]+\\.[0-9]+-ab\\.[1-9][0-9]*-linux-" + $arch + "$"))] | length
        ' <<<"${release_json}")"
        [[ "${lighthouse_asset_count}" -eq 1 ]] \
            || fail "The selected Release must contain exactly one AB Lighthouse linux-${platform_arch} binary; found ${lighthouse_asset_count}."
        lighthouse_asset_name="$(jq -r --arg arch "${platform_arch}" '
            .assets[] | select(.name | test("^ab-lighthouse-v[0-9]+\\.[0-9]+\\.[0-9]+-ab\\.[1-9][0-9]*-linux-" + $arch + "$")) | .name
        ' <<<"${release_json}")"
        [[ "$(jq --arg name "${lighthouse_asset_name}.sha256" '[.assets[] | select(.name == $name)] | length' <<<"${release_json}")" -eq 1 ]] \
            || fail "The selected Release must contain ${lighthouse_asset_name}.sha256."
        lighthouse_asset_url="$(jq -r --arg name "${lighthouse_asset_name}" '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release_json}")"
        lighthouse_checksum_url="$(jq -r --arg name "${lighthouse_asset_name}.sha256" '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release_json}")"
        resolved_lighthouse_version="${lighthouse_asset_name#ab-lighthouse-}"
        resolved_lighthouse_version="${resolved_lighthouse_version%-linux-${platform_arch}}"
    fi

    if [[ "${deployment_mode}" == "docker" ]]; then
        release_owner="${release_repo%%/*}"
        geth_image="${geth_image_override:-ghcr.io/${release_owner,,}/ab-geth:${resolved_geth_version}}"
    fi
}

function download_release() {
    local actual_sha256=""
    local archive_download_path
    local archive_path
    local archive_name
    local archive_listing
    local checksum_download_path
    local checksum_url
    local checksum_path
    local checksum_available=false
    local expected_sha256
    local local_archive=false
    local previous_share_dir
    local release_config_name
    local required_file
    local temporary_share_dir
    local member
    local normalized_member

    if [[ "${network_release_url}" == file://* ]]; then
        archive_path="${network_release_url#file://}"
        archive_path="${archive_path%%\?*}"
        [[ "${archive_path}" == /* ]] \
            || fail "Local Release URLs must use an absolute file:/// path."
        [[ -r "${archive_path}" ]] \
            || fail "Local network Release is not readable: ${archive_path}"
        checksum_path="${archive_path}.sha256"
        local_archive=true
        color "34" "Using local network Release: ${archive_path}"
    else
        archive_path="${PWD}/$(basename "${network_release_url%%\?*}")"
        checksum_url="${network_release_url}.sha256"
        checksum_path="${archive_path}.sha256"
    fi

    archive_name="$(basename "${archive_path}")"
    [[ "${archive_name}" == "${chain_name}-${network}-"*.tar.gz ]] \
        || fail "Network Release archive must be named ${chain_name}-${network}-<version>.tar.gz; got ${archive_name}."

    if [[ "${local_archive}" == true ]]; then
        [[ -s "${checksum_path}" ]] && checksum_available=true
    else
        checksum_download_path="$(mktemp "${checksum_path}.download.XXXXXX")"
        if curl -fsSL "${checksum_url}" -o "${checksum_download_path}"; then
            mv -f -- "${checksum_download_path}" "${checksum_path}"
            checksum_available=true
        else
            rm -f -- "${checksum_download_path}"
        fi

        if [[ "${checksum_available}" == true ]]; then
            expected_sha256="$(awk 'NR == 1 { print $1 }' "${checksum_path}")"
            [[ "${expected_sha256}" =~ ^[0-9a-fA-F]{64}$ ]] \
                || fail "Invalid checksum for ${archive_name}."
            if [[ -s "${archive_path}" ]]; then
                actual_sha256="$(sha256sum "${archive_path}" | awk '{ print $1 }')"
            fi
            if [[ "${actual_sha256,,}" == "${expected_sha256,,}" ]]; then
                color "32" "Using cached network Release: ${archive_path}"
            else
                [[ ! -e "${archive_path}" ]] \
                    || color "33" "Cached network Release failed checksum; downloading it again."
                archive_download_path="$(mktemp "${archive_path}.download.XXXXXX")"
                color "34" "Downloading network Release: ${network_release_url}"
                if ! curl -fL "${network_release_url}" -o "${archive_download_path}"; then
                    rm -f -- "${archive_download_path}"
                    fail "Unable to download ${archive_name}."
                fi
                actual_sha256="$(sha256sum "${archive_download_path}" | awk '{ print $1 }')"
                if [[ "${actual_sha256,,}" != "${expected_sha256,,}" ]]; then
                    rm -f -- "${archive_download_path}"
                    fail "Release checksum verification failed for ${archive_name}."
                fi
                mv -f -- "${archive_download_path}" "${archive_path}"
            fi
        else
            color "33" "Release checksum asset was not found; downloading without cache reuse."
            archive_download_path="$(mktemp "${archive_path}.download.XXXXXX")"
            color "34" "Downloading network Release: ${network_release_url}"
            if ! curl -fL "${network_release_url}" -o "${archive_download_path}"; then
                rm -f -- "${archive_download_path}"
                fail "Unable to download ${archive_name}."
            fi
            mv -f -- "${archive_download_path}" "${archive_path}"
        fi
    fi

    if [[ "${checksum_available}" == true ]]; then
        expected_sha256="$(awk 'NR == 1 { print $1 }' "${checksum_path}")"
        [[ "${expected_sha256}" =~ ^[0-9a-fA-F]{64}$ ]] \
            || fail "Invalid checksum for ${archive_name}."
        actual_sha256="$(sha256sum "${archive_path}" | awk '{ print $1 }')"
        [[ "${actual_sha256,,}" == "${expected_sha256,,}" ]] \
            || fail "Release checksum verification failed for ${archive_name}."
        printf '%s: OK\n' "${archive_name}"
    else
        color "33" "Continuing without checksum verification."
    fi

    archive_listing="$(mktemp "${data_dir}/.release-contents.XXXXXX")"
    if ! tar -tzf "${archive_path}" > "${archive_listing}"; then
        rm -f -- "${archive_listing}"
        fail "Unable to inspect the network Release archive."
    fi
    while IFS= read -r member; do
        normalized_member="${member#./}"
        [[ -n "${normalized_member}" ]] || continue
        [[ "${normalized_member}" != /* && "${normalized_member}" != */* ]] \
            || fail "The network Release contains an unsafe path: ${member}"
        [[ "${normalized_member}" != "jwtsecret" ]] \
            || fail "The network Release must not contain jwtsecret."
    done < "${archive_listing}"
    rm -f -- "${archive_listing}"

    temporary_share_dir="$(mktemp -d "${data_dir}/share-release.XXXXXX")"
    if ! tar -xzf "${archive_path}" -C "${temporary_share_dir}" \
        --no-same-owner --no-same-permissions; then
        rm -rf -- "${temporary_share_dir}"
        fail "Unable to extract the network Release."
    fi

    for required_file in genesis.json genesis.ssz config.yaml config.prysm.yaml \
        deposit_contract_block.txt genesis_validators_root.txt deposit-settings.json \
        client-versions.json; do
        if [[ ! -s "${temporary_share_dir}/${required_file}" ]]; then
            rm -rf -- "${temporary_share_dir}"
            fail "The network Release is missing required file: ${required_file}"
        fi
    done
    release_config_name="$(yaml_scalar "${temporary_share_dir}/config.yaml" CONFIG_NAME)"
    if [[ "${release_config_name}" != "${chain_name}-${network}" ]]; then
        rm -rf -- "${temporary_share_dir}"
        fail "Network Release CONFIG_NAME must be ${chain_name}-${network}; got ${release_config_name:-empty}."
    fi
    release_config_name="$(yaml_scalar "${temporary_share_dir}/config.prysm.yaml" CONFIG_NAME)"
    if [[ "${release_config_name}" != "${chain_name}-${network}" ]]; then
        rm -rf -- "${temporary_share_dir}"
        fail "Prysm CONFIG_NAME must be ${chain_name}-${network}; got ${release_config_name:-empty}."
    fi
    if [[ "${genesis_mode}" == false ]]; then
        for required_file in bootstrap_nodes.txt bootstrap_nodes_execution.txt; do
            if [[ ! -s "${temporary_share_dir}/${required_file}" ]]; then
                rm -rf -- "${temporary_share_dir}"
                fail "The network Release is missing required file: ${required_file}"
            fi
        done
    fi

    previous_share_dir="$(mktemp -d "${data_dir}/.share.previous.XXXXXX")"
    rmdir -- "${previous_share_dir}"
    if ! mv -- "${share_dir}" "${previous_share_dir}"; then
        rm -rf -- "${temporary_share_dir}"
        fail "Unable to prepare ${share_dir} for the network Release update."
    fi
    if ! mv -- "${temporary_share_dir}" "${share_dir}"; then
        mv -- "${previous_share_dir}" "${share_dir}" || true
        rm -rf -- "${temporary_share_dir}"
        fail "Unable to activate the downloaded network Release."
    fi
    rm -rf -- "${previous_share_dir}"
    color "32" "Updated network configuration in ${share_dir}."
}

function prepare_key_generation_settings() {
    local release_json
    local archive_name
    local archive_url
    local checksum_url
    local archive_path
    local checksum_path
    local expected_sha256
    local actual_sha256
    local temporary_dir
    local archive_listing
    local member
    local normalized_member
    local member_count=0
    local client_versions_count=0
    local release_tag
    local deposit_settings_member=""
    local client_versions_member=""

    if [[ -n "${deposit_settings_file}" ]]; then
        [[ -s "${deposit_settings_file}" ]] \
            || fail "Deposit settings file is missing or empty: ${deposit_settings_file}"
        return 0
    fi

    if [[ -z "${release_url}" ]]; then
        if [[ "${release_version}" == latest ]]; then
            release_json="$(curl -fsSL \
                "${github_api_url%/}/repos/${release_repo}/releases/latest")" \
                || fail "Unable to query the latest Network Release."
        else
            release_json="$(curl -fsSL \
                "${github_api_url%/}/repos/${release_repo}/releases/tags/${release_version}")" \
                || fail "Unable to query Release ${release_version}."
        fi
        release_tag="$(jq -r '.tag_name // empty' <<<"${release_json}")"
        [[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] \
            || fail "Selected Release has an invalid tag: ${release_tag:-empty}."
        if [[ "${release_tag}" == *-rc.0 ]]; then
            [[ "$(jq -r '.prerelease // false' <<<"${release_json}")" == true ]] \
                || fail "Genesis Participation Release ${release_tag} must be a Pre-release."
        fi
        archive_name="${chain_name}-${network}-${release_tag}.tar.gz"
        archive_url="$(jq -r --arg name "${archive_name}" \
            '[.assets[] | select(.name == $name)][0].browser_download_url // empty' \
            <<<"${release_json}")"
        checksum_url="$(jq -r --arg name "${archive_name}.sha256" \
            '[.assets[] | select(.name == $name)][0].browser_download_url // empty' \
            <<<"${release_json}")"
        [[ -n "${archive_url}" && -n "${checksum_url}" ]] \
            || fail "Release ${release_tag} does not contain ${archive_name} and its checksum."
    else
        archive_url="${release_url}"
        archive_name="$(basename "${archive_url%%\?*}")"
        [[ "${archive_name}" == "${chain_name}-${network}-"*.tar.gz ]] \
            || fail "Network archive name does not match ${chain_name}/${network}: ${archive_name}."
        checksum_url="${archive_url}.sha256"
    fi

    temporary_dir="$(mktemp -d /tmp/abpos-deposit-settings.XXXXXX)"
    archive_path="${temporary_dir}/${archive_name}"
    checksum_path="${archive_path}.sha256"
    color "34" "Downloading Deposit settings from Release: ${archive_url}"
    if [[ "${archive_url}" == file://* ]]; then
        cp -- "${archive_url#file://}" "${archive_path}"
        cp -- "${checksum_url#file://}" "${checksum_path}"
    else
        curl -fL "${archive_url}" -o "${archive_path}" \
            || fail "Unable to download ${archive_name}."
        curl -fsSL "${checksum_url}" -o "${checksum_path}" \
            || fail "Unable to download ${archive_name}.sha256."
    fi
    expected_sha256="$(awk 'NR == 1 { print $1 }' "${checksum_path}")"
    [[ "${expected_sha256}" =~ ^[0-9a-fA-F]{64}$ ]] \
        || fail "Invalid checksum for ${archive_name}."
    actual_sha256="$(sha256sum "${archive_path}" | awk '{ print $1 }')"
    [[ "${actual_sha256,,}" == "${expected_sha256,,}" ]] \
        || fail "Checksum verification failed for ${archive_name}."

    archive_listing="${temporary_dir}/archive-contents.txt"
    tar -tzf "${archive_path}" >"${archive_listing}" \
        || fail "Unable to inspect ${archive_name}."
    while IFS= read -r member; do
        normalized_member="${member#./}"
        [[ -n "${normalized_member}" ]] || continue
        [[ "${normalized_member}" != /* && "${normalized_member}" != */* ]] \
            || fail "The selected Release contains an unsafe path: ${member}"
        [[ "${normalized_member}" != jwtsecret ]] \
            || fail "The selected Release must not contain jwtsecret."
        if [[ "${normalized_member}" == deposit-settings.json ]]; then
            member_count=$((member_count + 1))
            deposit_settings_member="${member}"
        elif [[ "${normalized_member}" == client-versions.json ]]; then
            client_versions_count=$((client_versions_count + 1))
            client_versions_member="${member}"
        fi
    done <"${archive_listing}"
    [[ "${member_count}" -eq 1 ]] \
        || fail "The selected Release must contain exactly one deposit-settings.json."
    [[ "${client_versions_count}" -eq 1 ]] \
        || fail "The selected Release must contain exactly one client-versions.json."
    tar -xzf "${archive_path}" -C "${temporary_dir}" \
        "${deposit_settings_member}" "${client_versions_member}" \
        --no-same-owner --no-same-permissions \
        || fail "Unable to extract ${archive_name}."
    install -m 0644 "${temporary_dir}/deposit-settings.json" \
        "${share_dir}/deposit-settings.json"
    install -m 0644 "${temporary_dir}/client-versions.json" \
        "${share_dir}/client-versions.json"
    deposit_settings_file="${share_dir}/deposit-settings.json"
    rm -rf -- "${temporary_dir}"
    color "32" "Installed public Deposit settings: ${deposit_settings_file}"
}

function load_client_versions() {
    local versions_file="${share_dir}/client-versions.json"
    local locked_geth_version

    if [[ ! -s "${versions_file}" && "${key_generation_only}" == true \
        && -n "${deposit_settings_file}" ]]; then
        if [[ "${deployment_mode}" == docker ]]; then
            [[ -n "${deposit_cli_image_override}" ]] \
                || fail "--deposit-settings requires DEPOSIT_CLI_IMAGE when no client-versions.json is installed."
            deposit_cli_image="${deposit_cli_image_override}"
            require_explicit_image_tag "${deposit_cli_image}" "DEPOSIT_CLI_IMAGE"
        else
            [[ -n "${deposit_cli_release_version_override}" ]] \
                || fail "--deposit-settings requires DEPOSIT_CLI_RELEASE_VERSION when no client-versions.json is installed."
            deposit_cli_release_version="${deposit_cli_release_version_override}"
            require_release_version "${deposit_cli_release_version}" "DEPOSIT_CLI_RELEASE_VERSION"
        fi
        return 0
    fi
    [[ -s "${versions_file}" ]] \
        || fail "The selected Release does not contain client-versions.json."
    jq -e '
        . as $lock
        | type == "object"
        and (keys | sort) == (["geth", "prysm", "lighthouse", "deposit_cli"] | sort)
        and (.geth | keys | sort) == (["upstream_version", "ab_version"] | sort)
        and (.geth.upstream_version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
        and (.geth.ab_version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+-ab\\.[1-9][0-9]*$"))
        and (.prysm | keys | sort) == (["version", "beacon_image", "validator_image"] | sort)
        and (.lighthouse | keys | sort) == (["version", "ab_version", "image"] | sort)
        and (.deposit_cli | keys | sort) == (["version", "image"] | sort)
        and ([.prysm.version, .lighthouse.version, .deposit_cli.version]
             | all(test("^v[0-9]+\\.[0-9]+\\.[0-9]+([.-][0-9A-Za-z.-]+)?$")))
        and ([.prysm.beacon_image, .prysm.validator_image,
              .lighthouse.image, .deposit_cli.image]
             | all(test("^[^[:space:]@]+:[^[:space:]@]+$")))
        and ([.prysm.beacon_image, .prysm.validator_image,
              .lighthouse.image, .deposit_cli.image]
             | all((endswith(":latest") or endswith(":stable")) | not))
        and (.prysm.beacon_image | endswith(":" + $lock.prysm.version))
        and (.prysm.validator_image | endswith(":" + $lock.prysm.version))
        and (.lighthouse.ab_version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+-ab\\.[1-9][0-9]*$"))
        and (.lighthouse.ab_version | startswith($lock.lighthouse.version + "-ab."))
        and (.lighthouse.image | endswith(":" + $lock.lighthouse.ab_version))
        and (.deposit_cli.image | endswith(":" + $lock.deposit_cli.version))
    ' "${versions_file}" >/dev/null \
        || fail "Invalid client version lock: ${versions_file}"

    default_prysm_beacon_image="${prysm_beacon_image_override:-$(jq -r '.prysm.beacon_image' "${versions_file}")}"
    default_prysm_validator_image="${prysm_validator_image_override:-$(jq -r '.prysm.validator_image' "${versions_file}")}"
    default_lighthouse_image="${lighthouse_image_override:-$(jq -r '.lighthouse.image' "${versions_file}")}"
    deposit_cli_image="${deposit_cli_image_override:-$(jq -r '.deposit_cli.image' "${versions_file}")}"
    prysm_release_version="${prysm_release_version_override:-$(jq -r '.prysm.version' "${versions_file}")}"
    ab_lighthouse_version="$(jq -r '.lighthouse.ab_version' "${versions_file}")"
    deposit_cli_release_version="${deposit_cli_release_version_override:-$(jq -r '.deposit_cli.version' "${versions_file}")}"

    if [[ "${deployment_mode}" == docker ]]; then
        require_explicit_image_tag "${default_prysm_beacon_image}" "PRYSM_BEACON_IMAGE"
        require_explicit_image_tag "${default_prysm_validator_image}" "PRYSM_VALIDATOR_IMAGE"
        require_explicit_image_tag "${default_lighthouse_image}" "LIGHTHOUSE_IMAGE"
        require_explicit_image_tag "${deposit_cli_image}" "DEPOSIT_CLI_IMAGE"
    else
        require_release_version "${prysm_release_version}" "PRYSM_RELEASE_VERSION"
        require_release_version "${ab_lighthouse_version}" "AB Lighthouse version"
        require_release_version "${deposit_cli_release_version}" "DEPOSIT_CLI_RELEASE_VERSION"
    fi

    locked_geth_version="$(jq -r '.geth.ab_version' "${versions_file}")"
    if [[ -n "${resolved_geth_version}" && "${resolved_geth_version}" != "${locked_geth_version}" ]]; then
        fail "Network Release AB Geth asset ${resolved_geth_version} does not match client-versions.json ${locked_geth_version}."
    fi
    if [[ -n "${resolved_lighthouse_version}" && "${resolved_lighthouse_version}" != "${ab_lighthouse_version}" ]]; then
        fail "Network Release AB Lighthouse asset ${resolved_lighthouse_version} does not match client-versions.json ${ab_lighthouse_version}."
    fi
}

if [[ "${key_generation_only}" == true ]]; then
    prepare_key_generation_settings
else
    resolve_release
    download_release
fi
load_client_versions

if [[ "${key_generation_only}" == false ]]; then
    for required_file in genesis.json genesis.ssz config.yaml config.prysm.yaml \
        deposit_contract_block.txt genesis_validators_root.txt deposit-settings.json \
        client-versions.json; do
        [[ -s "${share_dir}/${required_file}" ]] || fail "Missing required file: ${share_dir}/${required_file}"
    done
fi
active_deposit_settings_file="${deposit_settings_file:-${share_dir}/deposit-settings.json}"
jq -e \
    --arg chain "${chain_name}" \
    '
        type == "object"
        and (keys | sort) == ([
            "network_name",
            "genesis_fork_version",
            "exit_fork_version",
            "genesis_validator_root",
            "multiplier",
            "divisor",
            "min_activation_amount",
            "min_deposit_amount"
        ] | sort)
        and .network_name == $chain
        and (.genesis_fork_version | test("^0x[0-9a-fA-F]{8}$"))
        and (.exit_fork_version | test("^0x[0-9a-fA-F]{8}$"))
        and (.genesis_validator_root | test("^0x[0-9a-fA-F]{64}$"))
        and (.multiplier | type == "number" and . > 0 and . == floor and . <= 9007199254740991)
        and (.divisor | type == "number" and . > 0 and . == floor and . <= 9007199254740991)
        and (.min_activation_amount | type == "number" and . > 0 and . == floor and . <= 9007199)
        and (.min_deposit_amount | type == "number" and . > 0 and . == floor and . <= 9007199)
        and .min_activation_amount >= .min_deposit_amount
    ' "${active_deposit_settings_file}" >/dev/null \
    || fail "Invalid deposit settings for ${chain_name}/${network}."
if [[ "${generate_keys}" == true && -z "${validator_deposit_amount}" ]]; then
    prompt_required_value \
        validator_deposit_amount \
        "Deposit amount per validator in native tokens (minimum $(jq -r '.min_activation_amount' "${active_deposit_settings_file}"))" \
        "--amount"
fi
if [[ "${generate_keys}" == true ]]; then
    validate_key_generation_amount
    confirm_validator_key_generation
fi
if [[ "${key_generation_only}" == false ]]; then
    settings_genesis_fork_version="$(jq -r \
        '.genesis_fork_version // empty' "${share_dir}/deposit-settings.json")"
    settings_exit_fork_version="$(jq -r \
        '.exit_fork_version // empty' "${share_dir}/deposit-settings.json")"
    settings_genesis_validators_root="$(jq -r \
        '.genesis_validator_root // empty' "${share_dir}/deposit-settings.json")"
    published_genesis_validators_root="$(tr -d '[:space:]' < "${share_dir}/genesis_validators_root.txt")"
    [[ "${settings_genesis_fork_version,,}" == \
        "$(yaml_scalar "${share_dir}/config.yaml" GENESIS_FORK_VERSION | tr '[:upper:]' '[:lower:]')" ]] \
        || fail "deposit-settings.json genesis_fork_version does not match config.yaml."
    [[ "${settings_exit_fork_version,,}" == \
        "$(yaml_scalar "${share_dir}/config.yaml" CAPELLA_FORK_VERSION | tr '[:upper:]' '[:lower:]')" ]] \
        || fail "deposit-settings.json exit_fork_version does not match CAPELLA_FORK_VERSION."
    [[ "${settings_genesis_validators_root,,}" == "${published_genesis_validators_root,,}" ]] \
        || fail "deposit-settings.json genesis_validator_root does not match genesis_validators_root.txt."
    if [[ "${genesis_mode}" == false ]]; then
        for required_file in bootstrap_nodes.txt bootstrap_nodes_execution.txt; do
            [[ -s "${share_dir}/${required_file}" ]] \
                || fail "Missing required file: ${share_dir}/${required_file}"
        done
    fi

    if [[ "${genesis_mode}" == false && -z "${checkpoint_url}" ]]; then
        checkpoint_url="$(first_data_line "${share_dir}/checkpoint_sync_urls.txt")"
        if [[ -z "${checkpoint_url}" ]]; then
            prompt_required_value \
                checkpoint_url \
                "Trusted checkpoint URL" \
                "--checkpoint-url"
        fi
    fi
fi

function github_release_json() {
    local repository="$1"
    local version="$2"
    local api_url="${github_api_url%/}/repos/${repository}/releases"

    if [[ "${version}" == "latest" ]]; then
        curl -fsSL "${api_url}/latest"
    else
        curl -fsSL "${api_url}/tags/${version}"
    fi
}

function install_deposit_cli_binary() {
    local release_json
    local release_tag
    local asset_count
    local asset_name
    local asset_url
    local checksum_url
    local expected_sha256
    local actual_sha256
    local temporary_dir
    local archive
    local extracted_binary

    release_json="$(github_release_json ethstaker/ethstaker-deposit-cli "${deposit_cli_release_version}")" \
        || fail "Unable to query the EthStaker Deposit CLI Release."
    release_tag="$(jq -r '.tag_name // empty' <<<"${release_json}")"
    [[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
        || fail "The EthStaker Deposit CLI Release has an invalid tag: ${release_tag:-empty}"
    asset_count="$(jq -r --arg arch "${platform_arch}" '
        [.assets[] | select(.name | test("^ethstaker_deposit-cli-[0-9a-f]+-linux-" + $arch + "\\.tar\\.gz$"))] | length
    ' <<<"${release_json}")"
    [[ "${asset_count}" -eq 1 ]] \
        || fail "EthStaker Deposit CLI Release ${release_tag} must contain exactly one linux-${platform_arch} archive; found ${asset_count}."
    asset_name="$(jq -r --arg arch "${platform_arch}" '
        [.assets[] | select(.name | test("^ethstaker_deposit-cli-[0-9a-f]+-linux-" + $arch + "\\.tar\\.gz$"))][0].name
    ' <<<"${release_json}")"
    asset_url="$(jq -r --arg name "${asset_name}" \
        '[.assets[] | select(.name == $name)][0].browser_download_url // empty' <<<"${release_json}")"
    checksum_url="$(jq -r --arg name "${asset_name}.sha256" \
        '[.assets[] | select(.name == $name)][0].browser_download_url // empty' <<<"${release_json}")"
    [[ -n "${asset_url}" && -n "${checksum_url}" ]] \
        || fail "EthStaker Deposit CLI Release ${release_tag} does not contain ${asset_name} and its checksum."

    temporary_dir="$(mktemp -d "${data_dir}/deposit-cli-download.XXXXXX")"
    archive="${temporary_dir}/${asset_name}"
    if ! curl -fL "${asset_url}" -o "${archive}" \
        || ! curl -fsSL "${checksum_url}" -o "${archive}.sha256"; then
        rm -rf -- "${temporary_dir}"
        fail "Unable to download ${asset_name} and its checksum."
    fi
    expected_sha256="$(awk 'NR == 1 { print $1 }' "${archive}.sha256")"
    [[ "${expected_sha256}" =~ ^[0-9a-fA-F]{64}$ ]] || {
        rm -rf -- "${temporary_dir}"
        fail "Invalid checksum file for ${asset_name}."
    }
    actual_sha256="$(sha256sum "${archive}" | awk '{ print $1 }')"
    [[ "${actual_sha256,,}" == "${expected_sha256,,}" ]] || {
        rm -rf -- "${temporary_dir}"
        fail "Checksum verification failed for ${asset_name}."
    }
    if ! tar -xzf "${archive}" -C "${temporary_dir}"; then
        rm -rf -- "${temporary_dir}"
        fail "Unable to extract ${asset_name}."
    fi
    extracted_binary="$(find "${temporary_dir}" -type f -name deposit -print -quit)"
    [[ -n "${extracted_binary}" ]] || {
        rm -rf -- "${temporary_dir}"
        fail "${asset_name} does not contain the deposit executable."
    }
    install -m 0755 "${extracted_binary}" "${bin_dir}/deposit.new"
    mv -f -- "${bin_dir}/deposit.new" "${bin_dir}/deposit"
    rm -rf -- "${temporary_dir}"
    printf '%s\n' "${release_tag}" >"${bin_dir}/deposit.version"
}

function generate_validator_keys() {
    local keys_parent
    local host_uid
    local host_gid
    local mnemonic
    local password
    local deposit_amount
    local chain_setting
    local deposit_cli_chain_setting
    local amount_multiplier
    local amount_divisor
    local public_amount_gwei
    local cli_amount_gwei
    local cli_deposit_amount
    local expected_deposit_gwei
    local public_minimum_activation_gwei
    local cli_minimum_activation_gwei
    local cli_minimum_activation_amount
    local public_minimum_deposit_gwei
    local cli_minimum_deposit_gwei
    local cli_minimum_deposit_amount
    local deposit_file
    local file
    local pubkey
    local generation_status=0
    local mnemonic_status=0
    local deposit_cli_log
    local duplicate_pubkey_count=0
    local mnemonic_directory
    local mnemonic_basename
    local -a before_files=()
    local -a new_files=()
    local -a new_keystores=()
    local -a new_deposit_files=()
    local -A existing_files=()
    local -A existing_pubkeys=()
    local -A generated_pubkeys=()

    keys_parent="$(dirname "${keys_dir}")"
    host_uid="${SUDO_UID:-$(id -u)}"
    host_gid="${SUDO_GID:-$(id -g)}"
    [[ "$(basename "${keys_dir}")" == validator_keys ]] \
        || fail "Key generation requires --keys-dir to end in /validator_keys."

    if [[ "${deployment_mode}" == "binary" ]]; then
        if [[ -z "${platform_arch}" ]]; then
            case "$(uname -m)" in
                x86_64 | amd64) platform_arch="amd64" ;;
                aarch64 | arm64) platform_arch="arm64" ;;
                *) fail "Unsupported host architecture: $(uname -m)" ;;
            esac
        fi
        install_deposit_cli_binary
    else
        require_command docker
        docker info >/dev/null 2>&1 \
            || fail "Docker is required to generate validator keys and is unavailable."
    fi

    mkdir -p "${keys_parent}" "${keys_dir}" "$(dirname "${mnemonic_file}")" \
        "$(dirname "${password_file}")"
    if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
        chown "${host_uid}:${host_gid}" "${keys_parent}" "${keys_dir}" \
            "$(dirname "${mnemonic_file}")" "$(dirname "${password_file}")"
    fi
    chmod 700 "${keys_parent}" "${keys_dir}"
    umask 077

    mapfile -t before_files < <(find "${keys_dir}" -maxdepth 1 -type f -print | sort)
    for file in "${before_files[@]}"; do
        existing_files["${file}"]=1
    done
    while IFS= read -r file; do
        pubkey="$(jq -r '.pubkey // empty' "${file}" | tr '[:upper:]' '[:lower:]')"
        pubkey="${pubkey#0x}"
        [[ "${pubkey}" =~ ^[0-9a-f]{96}$ ]] \
            || fail "Invalid validator pubkey in existing keystore: ${file}"
        existing_pubkeys["${pubkey}"]=1
    done < <(find "${keys_dir}" -maxdepth 1 -type f -name 'keystore-*.json' | sort)

    if [[ ! -s "${password_file}" ]]; then
        openssl rand -hex 32 >"${password_file}"
        chmod 600 "${password_file}"
    fi

    if [[ ! -s "${mnemonic_file}" ]]; then
        deposit_cli_log="$(mktemp "${keys_parent}/.deposit-cli-mnemonic.XXXXXX")"
        color "34" "Generating a validator mnemonic."
        if [[ "${deployment_mode}" == "binary" ]]; then
            "${bin_dir}/deposit" \
                --non_interactive --ignore_connectivity --language english \
                generate-mnemonic \
                --mnemonic_language=english \
                "--output_file=${mnemonic_file}" \
                >"${deposit_cli_log}" 2>&1 || mnemonic_status=$?
        else
            mnemonic_directory="$(dirname "${mnemonic_file}")"
            mnemonic_basename="$(basename "${mnemonic_file}")"
            docker run --rm \
                --user "${host_uid}:${host_gid}" \
                -v "${mnemonic_directory}:/app/mnemonic" \
                "${deposit_cli_image}" \
                --non_interactive --ignore_connectivity --language english \
                generate-mnemonic \
                --mnemonic_language=english \
                "--output_file=/app/mnemonic/${mnemonic_basename}" \
                >"${deposit_cli_log}" 2>&1 || mnemonic_status=$?
        fi
        if (( mnemonic_status != 0 )); then
            printf 'EthStaker Deposit CLI output:\n' >&2
            tail -n 100 "${deposit_cli_log}" >&2 || true
            rm -f -- "${deposit_cli_log}" "${mnemonic_file}"
            fail "EthStaker Deposit CLI failed while generating the mnemonic."
        fi
        rm -f -- "${deposit_cli_log}"
        chmod 600 "${mnemonic_file}"
    fi

    mnemonic="$(<"${mnemonic_file}")"
    password="$(<"${password_file}")"
    [[ -n "${validator_deposit_amount}" ]] \
        || fail "--amount is required when generating new validator keys."
    deposit_amount="${validator_deposit_amount}"
    jq -e \
        --arg chain "${chain_name}" '
            type == "object"
            and (keys | sort) == ([
                "network_name",
                "genesis_fork_version",
                "exit_fork_version",
                "genesis_validator_root",
                "multiplier",
                "divisor",
                "min_activation_amount",
                "min_deposit_amount"
            ] | sort)
            and .network_name == $chain
            and (.genesis_fork_version | test("^0x[0-9a-fA-F]{8}$"))
            and (.exit_fork_version | test("^0x[0-9a-fA-F]{8}$"))
            and (.genesis_validator_root | test("^0x[0-9a-fA-F]{64}$"))
            and (.multiplier | type == "number" and . > 0 and . == floor and . <= 9007199254740991)
            and (.divisor | type == "number" and . > 0 and . == floor and . <= 9007199254740991)
            and (.min_activation_amount | type == "number" and . > 0 and . == floor and . <= 9007199)
            and (.min_deposit_amount | type == "number" and . > 0 and . == floor and . <= 9007199)
            and .min_activation_amount >= .min_deposit_amount
        ' "${active_deposit_settings_file}" >/dev/null \
        || fail "Invalid Deposit settings: ${active_deposit_settings_file}."
    chain_setting="$(jq -c '.' "${active_deposit_settings_file}")"
    amount_multiplier="$(jq -r '.multiplier' <<<"${chain_setting}")"
    amount_divisor="$(jq -r '.divisor' <<<"${chain_setting}")"
    parse_whole_token_amount_to_gwei "--amount" "${deposit_amount}"
    public_amount_gwei="${parsed_gwei}"
    (( public_amount_gwei % amount_divisor == 0 )) \
        || fail "--amount cannot be represented exactly with the published Deposit conversion."
    cli_amount_gwei=$((public_amount_gwei / amount_divisor))
    (( cli_amount_gwei <= max_exact_integer / amount_multiplier )) \
        || fail "--amount is too large after applying the published Deposit conversion."
    expected_deposit_gwei=$((cli_amount_gwei * amount_multiplier))
    parse_whole_token_amount_to_gwei \
        "Published minimum activation amount" \
        "$(jq -r '.min_activation_amount' <<<"${chain_setting}")"
    public_minimum_activation_gwei="${parsed_gwei}"
    (( public_minimum_activation_gwei % amount_divisor == 0 )) \
        || fail "Published minimum activation amount cannot be represented exactly."
    cli_minimum_activation_gwei=$((public_minimum_activation_gwei / amount_divisor))
    (( public_amount_gwei >= public_minimum_activation_gwei )) \
        || fail "--amount must be at least $(jq -r '.min_activation_amount' <<<"${chain_setting}")."
    parse_whole_token_amount_to_gwei \
        "Published minimum Deposit amount" \
        "$(jq -r '.min_deposit_amount' <<<"${chain_setting}")"
    public_minimum_deposit_gwei="${parsed_gwei}"
    (( public_minimum_deposit_gwei % amount_divisor == 0 )) \
        || fail "Published minimum Deposit amount cannot be represented exactly."
    cli_minimum_deposit_gwei=$((public_minimum_deposit_gwei / amount_divisor))
    format_gwei_amount "${cli_amount_gwei}"
    cli_deposit_amount="${formatted_amount}"
    format_gwei_amount "${cli_minimum_activation_gwei}"
    cli_minimum_activation_amount="${formatted_amount}"
    format_gwei_amount "${cli_minimum_deposit_gwei}"
    cli_minimum_deposit_amount="${formatted_amount}"
    deposit_cli_chain_setting="$(jq -c \
        --argjson min_activation_amount "${cli_minimum_activation_amount}" \
        --argjson min_deposit_amount "${cli_minimum_deposit_amount}" '
            del(.divisor)
            | .min_activation_amount = $min_activation_amount
            | .min_deposit_amount = $min_deposit_amount
        ' <<<"${chain_setting}")"

    color "34" "Generating ${validator_count} validator key(s) from index ${validator_start_index}."
    deposit_cli_log="$(mktemp "${keys_parent}/.deposit-cli-keys.XXXXXX")"
    if [[ "${deployment_mode}" == "binary" ]]; then
        "${bin_dir}/deposit" \
            --non_interactive --ignore_connectivity --language english \
            existing-mnemonic \
            --mnemonic="${mnemonic}" \
            --keystore_password="${password}" \
            --validator_start_index="${validator_start_index}" \
            --num_validators="${validator_count}" \
            --withdrawal_address="${withdrawal_address}" \
            --compounding \
            --amount="${cli_deposit_amount}" \
            --devnet_chain_setting="${deposit_cli_chain_setting}" \
            "--folder=${keys_parent}" \
            >"${deposit_cli_log}" 2>&1 || generation_status=$?
    else
        docker run --rm \
            --user "${host_uid}:${host_gid}" \
            -v "${keys_dir}:/app/validator_keys" \
            "${deposit_cli_image}" \
            --non_interactive --ignore_connectivity --language english \
            existing-mnemonic \
            --mnemonic="${mnemonic}" \
            --keystore_password="${password}" \
            --validator_start_index="${validator_start_index}" \
            --num_validators="${validator_count}" \
            --withdrawal_address="${withdrawal_address}" \
            --compounding \
            --amount="${cli_deposit_amount}" \
            --devnet_chain_setting="${deposit_cli_chain_setting}" \
            --folder=/app \
            >"${deposit_cli_log}" 2>&1 || generation_status=$?
    fi

    unset mnemonic password
    while IFS= read -r file; do
        [[ -n "${existing_files[${file}]:-}" ]] && continue
        new_files+=("${file}")
        case "$(basename "${file}")" in
            keystore-*.json) new_keystores+=("${file}") ;;
            deposit_data-*.json) new_deposit_files+=("${file}") ;;
        esac
    done < <(find "${keys_dir}" -maxdepth 1 -type f -print | sort)

    if (( generation_status != 0 )); then
        printf 'EthStaker Deposit CLI output:\n' >&2
        tail -n 100 "${deposit_cli_log}" >&2 || true
        rm -f -- "${deposit_cli_log}"
        [[ "${#new_files[@]}" -eq 0 ]] || rm -f -- "${new_files[@]}"
        fail "EthStaker Deposit CLI failed; removed files from the incomplete batch."
    fi
    rm -f -- "${deposit_cli_log}"
    if [[ "${#new_keystores[@]}" -ne "${validator_count}" \
        || "${#new_deposit_files[@]}" -ne 1 ]]; then
        [[ "${#new_files[@]}" -eq 0 ]] || rm -f -- "${new_files[@]}"
        fail "Expected ${validator_count} new keystores and one new deposit data file; removed the incomplete batch."
    fi

    for file in "${new_keystores[@]}"; do
        pubkey="$(jq -r '.pubkey // empty' "${file}" | tr '[:upper:]' '[:lower:]')"
        pubkey="${pubkey#0x}"
        if [[ ! "${pubkey}" =~ ^[0-9a-f]{96}$ ]]; then
            rm -f -- "${new_files[@]}"
            fail "Generated an invalid validator pubkey; removed the incomplete batch."
        fi
        if [[ -n "${existing_pubkeys[${pubkey}]:-}" \
            || -n "${generated_pubkeys[${pubkey}]:-}" ]]; then
            duplicate_pubkey_count=$((duplicate_pubkey_count + 1))
        else
            generated_unique_validator_keys=$((generated_unique_validator_keys + 1))
        fi
        generated_pubkeys["${pubkey}"]=1
    done

    deposit_file="${new_deposit_files[0]}"
    jq -e \
        --arg chain "${chain_name}" \
        --arg fork_version "$(jq -r '.genesis_fork_version' <<<"${chain_setting}")" \
        --argjson expected_amount "${expected_deposit_gwei}" \
        --argjson validator_count "${validator_count}" '
            type == "array"
            and length == $validator_count
            and ([.[].pubkey | ascii_downcase] | unique | length) == $validator_count
            and all(.[];
                .network_name == $chain
                and (("0x" + (.fork_version | sub("^0x"; ""))) | ascii_downcase)
                    == ($fork_version | ascii_downcase)
                and .amount == $expected_amount
            )
        ' "${deposit_file}" >/dev/null \
        || {
            rm -f -- "${new_files[@]}"
            fail "Generated deposit data does not match ${active_deposit_settings_file}; removed the new batch."
        }

    while IFS= read -r pubkey; do
        pubkey="${pubkey#0x}"
        [[ -n "${generated_pubkeys[${pubkey}]:-}" ]] || {
            rm -f -- "${new_files[@]}"
            fail "Generated deposit data does not match the new keystores; removed the new batch."
        }
    done < <(jq -r '.[].pubkey | ascii_downcase' "${deposit_file}")

    if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
        chown "${host_uid}:${host_gid}" "${mnemonic_file}" "${password_file}" \
            "${new_files[@]}"
    fi

    if (( duplicate_pubkey_count > 0 )); then
        color "33" "WARNING: Duplicate validator pubkeys: ${duplicate_pubkey_count} of ${validator_count}."
    fi
    color "32" "Generated ${validator_count} validator keys."
    color "32" "Mnemonic: ${mnemonic_file}"
    color "32" "Keystore password: ${password_file}"
    color "32" "Keystores: ${keys_dir}"
    color "32" "Deposit data: ${deposit_file}"
    color "33" "Submit the deposit data before expecting the validators to activate."
    color "31" "Never share ${mnemonic_file}, ${password_file}, or validator keystores."
}

if [[ "${generate_keys}" == true ]]; then
    generate_validator_keys
fi

if [[ "${key_generation_only}" == true ]]; then
    color "32" "Validator key generation completed. No node services were changed."
    exit 0
fi

if [[ "${validator_mode}" == true ]]; then
    if validator_key_import_required; then
        existing_keys="$(find "${keys_dir}" -maxdepth 1 -type f -name 'keystore-*.json' | wc -l | tr -d ' ')"
        [[ "${existing_keys}" -gt 0 ]] \
            || fail "Validator mode requires existing keystores in ${keys_dir}; use --generate-keys to create them."
        [[ -s "${password_file}" ]] || fail "Missing validator password file: ${password_file}"
    else
        color "33" "Using the validator keys already imported in ${validator_data_dir}."
    fi
    if [[ "${consensus_client}" == "prysm" ]]; then
        [[ -s "${password_file}" ]] || fail "Missing Prysm wallet password file: ${password_file}"
        save_validator_password_reference
    fi
    mkdir -p "${validator_data_dir}"
fi

resolve_saved_block_metadata

network_id="$(jq -r '.config.chainId' "${share_dir}/genesis.json")"
[[ "${network_id}" =~ ^[0-9]+$ ]] || fail "Invalid chainId in genesis.json."
bootnodes=""
if [[ -f "${share_dir}/bootstrap_nodes_execution.txt" ]]; then
    bootnodes="$(sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${share_dir}/bootstrap_nodes_execution.txt" | paste -sd, -)"
fi

function download_verified_binary() {
    local asset_name="$1"
    local asset_url="$2"
    local checksum_url="$3"
    local destination="$4"
    local temporary_dir
    local expected_sha256
    local actual_sha256

    temporary_dir="$(mktemp -d "${data_dir}/binary-download.XXXXXX")"
    if ! curl -fL "${asset_url}" -o "${temporary_dir}/${asset_name}"; then
        rm -rf -- "${temporary_dir}"
        fail "Unable to download ${asset_name}."
    fi
    if ! curl -fsSL "${checksum_url}" -o "${temporary_dir}/${asset_name}.sha256"; then
        rm -rf -- "${temporary_dir}"
        fail "Unable to download the checksum for ${asset_name}."
    fi
    expected_sha256="$(awk 'NR == 1 { print $1 }' "${temporary_dir}/${asset_name}.sha256")"
    [[ "${expected_sha256}" =~ ^[0-9a-fA-F]{64}$ ]] || {
        rm -rf -- "${temporary_dir}"
        fail "Invalid checksum file for ${asset_name}."
    }
    actual_sha256="$(sha256sum "${temporary_dir}/${asset_name}" | awk '{ print $1 }')"
    if [[ "${actual_sha256,,}" != "${expected_sha256,,}" ]]; then
        rm -rf -- "${temporary_dir}"
        fail "Checksum verification failed for ${asset_name}."
    fi
    install -m 0755 "${temporary_dir}/${asset_name}" "${destination}.new"
    mv -f -- "${destination}.new" "${destination}"
    rm -rf -- "${temporary_dir}"
}

function install_ab_geth_binary() {
    local asset_name="${geth_asset_name}"

    [[ -n "${asset_name}" ]] || asset_name="$(basename "${geth_asset_url%%\?*}")"
    [[ -n "${asset_name}" && -n "${geth_asset_url}" && -n "${geth_checksum_url}" ]] \
        || fail "The selected Network Release does not provide a verifiable AB Geth binary."
    color "34" "Installing AB Geth binary: ${asset_name}"
    download_verified_binary "${asset_name}" "${geth_asset_url}" "${geth_checksum_url}" "${bin_dir}/geth"
}

function install_prysm_binaries() {
    local release_json
    local release_tag
    local component
    local asset_name
    local asset_url
    local checksum_url

    release_json="$(github_release_json OffchainLabs/prysm "${prysm_release_version}")" \
        || fail "Unable to query the Prysm Release."
    release_tag="$(jq -r '.tag_name // empty' <<<"${release_json}")"
    [[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
        || fail "The Prysm Release has an invalid tag: ${release_tag:-empty}"

    for component in beacon-chain validator; do
        [[ "${component}" == "beacon-chain" || "${validator_mode}" == true ]] || continue
        asset_name="${component}-${release_tag}-linux-${platform_arch}"
        asset_url="$(jq -r --arg name "${asset_name}" \
            '[.assets[] | select(.name == $name)][0].browser_download_url // empty' <<<"${release_json}")"
        checksum_url="$(jq -r --arg name "${asset_name}.sha256" \
            '[.assets[] | select(.name == $name)][0].browser_download_url // empty' <<<"${release_json}")"
        [[ -n "${asset_url}" && -n "${checksum_url}" ]] \
            || fail "Prysm Release ${release_tag} does not contain ${asset_name} and its checksum."
        if [[ "${component}" == "beacon-chain" ]]; then
            download_verified_binary "${asset_name}" "${asset_url}" "${checksum_url}" "${bin_dir}/prysm-beacon"
        else
            download_verified_binary "${asset_name}" "${asset_url}" "${checksum_url}" "${bin_dir}/prysm-validator"
        fi
    done
    printf '%s\n' "${release_tag}" >"${bin_dir}/prysm.version"
}

function install_lighthouse_binary() {
    local asset_url="${lighthouse_binary_url_override:-${lighthouse_asset_url}}"
    local checksum_url="${lighthouse_binary_checksum_url_override:-${lighthouse_checksum_url}}"
    local asset_name="ab-lighthouse-${ab_lighthouse_version}-linux-${platform_arch}"

    if [[ -n "${lighthouse_binary_url_override}" || -n "${lighthouse_binary_checksum_url_override}" ]]; then
        [[ -n "${lighthouse_binary_url_override}" && -n "${lighthouse_binary_checksum_url_override}" ]] \
            || fail "Provide both AB_LIGHTHOUSE_BINARY_URL and AB_LIGHTHOUSE_BINARY_SHA256_URL."
    fi
    [[ -n "${asset_url}" && -n "${checksum_url}" ]] \
        || fail "The selected Network Release does not provide a verified AB Lighthouse binary."
    download_verified_binary "${asset_name}" "${asset_url}" "${checksum_url}" "${bin_dir}/lighthouse"
}

function write_binary_launcher() {
    local service="$1"
    local executable="$2"
    local launcher
    local temporary_launcher
    shift 2

    launcher="$(binary_launcher_file "${service}")"
    temporary_launcher="$(mktemp "${run_dir}/.${service}.XXXXXX")"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec %q' "${executable}"
        printf ' %q' "$@"
        printf '\n'
    } >"${temporary_launcher}"
    chmod 0755 "${temporary_launcher}"
    mv -f -- "${temporary_launcher}" "${launcher}"
    printf '%s\n' "${executable}" >"$(binary_executable_file "${service}")"
}

function import_prysm_keys_binary() {
    local import_log
    local import_status=0

    if ! validator_key_import_required; then
        return 0
    fi
    if [[ ! -f "${validator_data_dir}/direct/accounts/all-accounts.keystore.json" ]]; then
        "${bin_dir}/prysm-validator" wallet create --accept-terms-of-use=true \
            "--wallet-dir=${validator_data_dir}" "--wallet-password-file=${password_file}" \
            --keymanager-kind=imported
    fi
    import_log="$(mktemp "${data_dir}/prysm-import.XXXXXX")"
    "${bin_dir}/prysm-validator" accounts import --accept-terms-of-use=true \
        "--wallet-dir=${validator_data_dir}" "--wallet-password-file=${password_file}" \
        "--account-password-file=${password_file}" "--keys-dir=${keys_dir}" \
        >"${import_log}" 2>&1 || import_status=$?
    cat "${import_log}"
    if (( import_status != 0 )); then
        if prysm_import_was_duplicate_only "${import_log}"; then
            color "33" "All supplied Prysm validator keys were already imported."
        else
            rm -f -- "${import_log}"
            return "${import_status}"
        fi
    fi
    rm -f -- "${import_log}"
}

function import_lighthouse_keys_binary() {
    if ! validator_key_import_required; then
        return 0
    fi
    "${bin_dir}/lighthouse" account validator import \
        "--testnet-dir=${share_dir}" "--datadir=${validator_data_dir}" \
        "--directory=${keys_dir}" --reuse-password "--password-file=${password_file}"
}

function chain_config_files_match() {
    local stored_genesis="$1"
    local release_genesis="$2"

    jq -e '.config | type == "object"' "${stored_genesis}" >/dev/null || return 2
    jq -e '.config | type == "object"' "${release_genesis}" >/dev/null || return 2
    [[ "$(jq -cS '.config' "${stored_genesis}")" \
        == "$(jq -cS '.config' "${release_genesis}")" ]]
}

function geth_binary_chain_config_matches_release() {
    local stored_genesis
    local dump_log
    local status=0

    stored_genesis="$(mktemp "${data_dir}/.stored-genesis.XXXXXX")"
    dump_log="$(mktemp "${data_dir}/.dumpgenesis.XXXXXX")"
    if ! "${bin_dir}/geth" "--datadir=${geth_data_dir}" dumpgenesis \
        >"${stored_genesis}" 2>"${dump_log}"; then
        cat "${dump_log}" >&2
        rm -f -- "${stored_genesis}" "${dump_log}"
        fail "Unable to read the existing Geth genesis configuration; refusing to reinitialize it."
    fi
    rm -f -- "${dump_log}"
    chain_config_files_match "${stored_genesis}" "${share_dir}/genesis.json" || status=$?
    rm -f -- "${stored_genesis}"
    (( status <= 1 )) \
        || fail "Unable to compare the stored and Release Geth chain configurations."
    return "${status}"
}

function deploy_binary_node() {
    local service
    local lighthouse_bootnodes
    local -a geth_binary_args
    local -a beacon_binary_args
    local -a validator_binary_args
    local -a binary_bootstrap_args

    install_ab_geth_binary
    if [[ "${consensus_client}" == "prysm" ]]; then
        install_prysm_binaries
    else
        install_lighthouse_binary
    fi

    for service in validator beacon geth; do
        stop_binary_service "${service}"
    done

    prepare_geth_nodekey
    if [[ "${consensus_client}" == "prysm" ]]; then
        prepare_prysm_p2p_key
    else
        prepare_lighthouse_network_identity
    fi

    if [[ ! -d "${geth_data_dir}/geth/chaindata" ]]; then
        color "34" "Initializing Geth from genesis.json."
        "${bin_dir}/geth" "--datadir=${geth_data_dir}" init "${share_dir}/genesis.json"
    elif geth_binary_chain_config_matches_release; then
        color "32" "Geth chain configuration is unchanged; skipping init."
    else
        color "34" "Updating Geth chain configuration from genesis.json."
        "${bin_dir}/geth" "--datadir=${geth_data_dir}" init "${share_dir}/genesis.json"
    fi
    persist_generated_geth_nodekey

    geth_binary_args=(
        "--datadir=${geth_data_dir}"
        "--nodekey=${geth_nodekey_file}"
        "--networkid=${network_id}"
        --port=30303
        --http
        --http.addr=127.0.0.1
        --http.port=8545
        --http.api=eth,net,web3,admin
        --rpc.txfeecap=1000
        --authrpc.addr=127.0.0.1
        --authrpc.port=8551
        --authrpc.vhosts=\*
        "--authrpc.jwtsecret=${jwt_secret_file}"
        --syncmode=full
        "${geth_metadata_args[@]}"
    )
    [[ "${archive_mode}" == true ]] && geth_binary_args+=(--gcmode=archive)
    [[ -n "${bootnodes}" ]] && geth_binary_args+=("--bootnodes=${bootnodes}")
    [[ -z "${node_public_ip}" ]] || geth_binary_args+=("--nat=extip:${node_public_ip}")
    write_binary_launcher geth "${bin_dir}/geth" "${geth_binary_args[@]}"

    mapfile -t binary_bootstrap_args < <(
        if [[ -f "${share_dir}/bootstrap_nodes.txt" ]]; then
            sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${share_dir}/bootstrap_nodes.txt"
        fi
    )
    if [[ "${consensus_client}" == "prysm" ]]; then
        beacon_binary_args=(
            --accept-terms-of-use=true
            "--datadir=${beacon_data_dir}"
            "--chain-config-file=${share_dir}/config.prysm.yaml"
            "--genesis-state=${share_dir}/genesis.ssz"
            --execution-endpoint=http://127.0.0.1:8551
            "--jwt-secret=${jwt_secret_file}"
            --contract-deployment-block=0
            --min-sync-peers=1
            --p2p-tcp-port=13000
            --p2p-udp-port=12000
            --rpc-host=127.0.0.1
            --rpc-port=4000
            --http-host=127.0.0.1
            --http-port=3500
        )
        if [[ -s "${prysm_p2p_key_file}" ]]; then
            beacon_binary_args+=("--p2p-priv-key=${prysm_p2p_key_file}")
        else
            beacon_binary_args+=(--p2p-static-id)
        fi
        [[ -z "${node_public_ip}" ]] \
            || beacon_binary_args+=("--p2p-host-ip=${node_public_ip}")
        [[ "${genesis_mode}" == false ]] \
            && beacon_binary_args+=("--checkpoint-sync-url=${checkpoint_url}")
        for enr in "${binary_bootstrap_args[@]}"; do
            beacon_binary_args+=("--bootstrap-node=${enr}")
        done
        write_binary_launcher beacon "${bin_dir}/prysm-beacon" "${beacon_binary_args[@]}"
    else
        beacon_binary_args=(
            bn
            "--testnet-dir=${share_dir}"
            "--datadir=${beacon_data_dir}"
            "--network-dir=${lighthouse_network_dir}"
            --execution-endpoint=http://127.0.0.1:8551
            "--execution-jwt=${jwt_secret_file}"
            --http
            --http-address=127.0.0.1
            --http-port=3500
            --port=13000
            --discovery-port=12000
        )
        [[ -z "${node_public_ip}" ]] \
            || beacon_binary_args+=("--enr-address=${node_public_ip}")
        [[ "${genesis_mode}" == false ]] \
            && beacon_binary_args+=("--checkpoint-sync-url=${checkpoint_url}")
        if [[ "${#binary_bootstrap_args[@]}" -gt 0 ]]; then
            lighthouse_bootnodes="$(IFS=,; echo "${binary_bootstrap_args[*]}")"
            beacon_binary_args+=("--boot-nodes=${lighthouse_bootnodes}")
        fi
        write_binary_launcher beacon "${bin_dir}/lighthouse" "${beacon_binary_args[@]}"
    fi

    rm -f -- "$(binary_launcher_file validator)" "$(binary_executable_file validator)"
    if [[ "${validator_mode}" == true ]]; then
        if [[ "${consensus_client}" == "prysm" ]]; then
            import_prysm_keys_binary
            validator_binary_args=(
                --accept-terms-of-use=true
                "--datadir=${validator_data_dir}"
                "--chain-config-file=${share_dir}/config.prysm.yaml"
                --beacon-rpc-provider=127.0.0.1:4000
                "--wallet-dir=${validator_data_dir}"
                "--wallet-password-file=${password_file}"
                "--suggested-fee-recipient=${fee_recipient}"
                "${validator_metadata_args[@]}"
            )
            write_binary_launcher validator "${bin_dir}/prysm-validator" "${validator_binary_args[@]}"
        else
            import_lighthouse_keys_binary
            validator_binary_args=(
                vc
                "--testnet-dir=${share_dir}"
                "--datadir=${validator_data_dir}"
                --beacon-nodes=http://127.0.0.1:3500
                "--suggested-fee-recipient=${fee_recipient}"
                --init-slashing-protection
                "${validator_metadata_args[@]}"
            )
            write_binary_launcher validator "${bin_dir}/lighthouse" "${validator_binary_args[@]}"
        fi
    fi

    start_binary_service geth
    start_binary_service beacon
    if [[ "${consensus_client}" == "prysm" ]]; then
        persist_generated_prysm_p2p_key
    else
        persist_generated_lighthouse_network_identity
    fi
    if [[ "${validator_mode}" == true ]]; then
        start_binary_service validator
    fi
}

if [[ "${deployment_mode}" == "binary" ]]; then
    deploy_binary_node
    color "32" "AB PoS node installation completed."
    color "37" "Chain: ${chain_name}"
    color "37" "Network: ${network}"
    color "37" "Consensus client: ${consensus_client}"
    color "37" "Execution client: geth"
    color "37" "Deployment: native binaries"
    color "37" "Binary directory: ${bin_dir}"
    color "37" "Data directory: ${data_dir}"
    color "37" "Synchronization source: $([[ "${genesis_mode}" == true ]] && echo genesis || echo checkpoint)"
    show_binary_status true
    show_genesis_node_information
    exit 0
fi

function geth_chain_config_matches_release() {
    local stored_genesis
    local dump_log
    local status=0

    stored_genesis="$(mktemp "${data_dir}/.stored-genesis.XXXXXX")"
    dump_log="$(mktemp "${data_dir}/.dumpgenesis.XXXXXX")"
    if ! docker run --rm \
        -v "${geth_data_dir}:/data" \
        "${geth_image}" \
        --datadir=/data dumpgenesis >"${stored_genesis}" 2>"${dump_log}"; then
        cat "${dump_log}" >&2
        rm -f -- "${stored_genesis}" "${dump_log}"
        fail "Unable to read the existing Geth genesis configuration; refusing to reinitialize it."
    fi
    rm -f -- "${dump_log}"
    chain_config_files_match "${stored_genesis}" "${share_dir}/genesis.json" || status=$?
    rm -f -- "${stored_genesis}"
    (( status <= 1 )) \
        || fail "Unable to compare the stored and Release Geth chain configurations."
    return "${status}"
}

replace_role_containers execution "${geth_data_dir}"
prepare_geth_nodekey
if [[ ! -d "${geth_data_dir}/geth/chaindata" ]]; then
    color "34" "Initializing Geth from genesis.json."
    docker run --rm \
        -v "${geth_data_dir}:/data" \
        -v "${share_dir}:/share:ro" \
        "${geth_image}" \
        --datadir=/data init /share/genesis.json
elif geth_chain_config_matches_release; then
    color "32" "Geth chain configuration is unchanged; skipping init."
else
    color "34" "Updating Geth chain configuration from genesis.json."
    docker run --rm \
        -v "${geth_data_dir}:/data" \
        -v "${share_dir}:/share:ro" \
        "${geth_image}" \
        --datadir=/data init /share/genesis.json
fi
persist_generated_geth_nodekey
geth_args=(
    --datadir=/data
    --nodekey=/node-config/nodekey
    "--networkid=${network_id}"
    --port=30303
    --http
    --http.addr=127.0.0.1
    --http.port=8545
    --http.api=eth,net,web3,admin
    --rpc.txfeecap=1000
    --authrpc.addr=127.0.0.1
    --authrpc.port=8551
    --authrpc.vhosts=\*
    --authrpc.jwtsecret=/jwtsecret
    "${geth_metadata_args[@]}"
)
if [[ "${archive_mode}" == true ]]; then
    geth_args+=(--syncmode=full --gcmode=archive)
else
    geth_args+=(--syncmode=full)
fi
[[ -n "${bootnodes}" ]] && geth_args+=("--bootnodes=${bootnodes}")
[[ -z "${node_public_ip}" ]] || geth_args+=("--nat=extip:${node_public_ip}")

docker run -d \
    --name "${geth_container}" \
    --label "io.abpos.chain=${chain_name}" \
    --label "io.abpos.network=${network}" \
    --label "io.abpos.role=execution" \
    --restart unless-stopped \
    --network host \
    -v "${geth_data_dir}:/data" \
    -v "${geth_config_dir}:/node-config:ro" \
    -v "${share_dir}:/share:ro" \
    -v "${jwt_secret_file}:/jwtsecret:ro" \
    "${geth_image}" "${geth_args[@]}" >/dev/null

mapfile -t bootstrap_args < <(
    if [[ -f "${share_dir}/bootstrap_nodes.txt" ]]; then
        sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${share_dir}/bootstrap_nodes.txt"
    fi
)

replace_role_containers consensus "${data_dir}/prysm" "${data_dir}/lighthouse"
if [[ "${consensus_client}" == "prysm" ]]; then
    prepare_prysm_p2p_key
    beacon_args=(
        --accept-terms-of-use=true
        --datadir=/data
        --chain-config-file=/share/config.prysm.yaml
        --genesis-state=/share/genesis.ssz
        --execution-endpoint=http://127.0.0.1:8551
        --jwt-secret=/jwtsecret
        --contract-deployment-block=0
        --min-sync-peers=1
        --p2p-tcp-port=13000
        --p2p-udp-port=12000
        --rpc-host=127.0.0.1
        --rpc-port=4000
        --http-host=127.0.0.1
        --http-port=3500
    )
    if [[ -s "${prysm_p2p_key_file}" ]]; then
        beacon_args+=(--p2p-priv-key=/node-config/p2p.key)
    else
        beacon_args+=(--p2p-static-id)
    fi
    [[ -z "${node_public_ip}" ]] || beacon_args+=("--p2p-host-ip=${node_public_ip}")
    [[ "${genesis_mode}" == false ]] && beacon_args+=("--checkpoint-sync-url=${checkpoint_url}")
    for enr in "${bootstrap_args[@]}"; do
        beacon_args+=("--bootstrap-node=${enr}")
    done
    docker run -d \
        --name "${beacon_container}" \
        --label "io.abpos.chain=${chain_name}" \
        --label "io.abpos.network=${network}" \
        --label "io.abpos.role=consensus" \
        --label "io.abpos.consensus-client=${consensus_client}" \
        --restart unless-stopped --network host \
        -v "${beacon_data_dir}:/data" -v "${share_dir}:/share:ro" \
        -v "${prysm_config_dir}:/node-config:ro" \
        -v "${jwt_secret_file}:/jwtsecret:ro" \
        "${default_prysm_beacon_image}" "${beacon_args[@]}" >/dev/null
    persist_generated_prysm_p2p_key
else
    prepare_lighthouse_network_identity
    beacon_args=(
        lighthouse bn
        --testnet-dir=/share
        --datadir=/data
        --network-dir=/node-network
        --execution-endpoint=http://127.0.0.1:8551
        --execution-jwt=/jwtsecret
        --http
        --http-address=127.0.0.1
        --http-port=3500
        --port=13000
        --discovery-port=12000
    )
    [[ -z "${node_public_ip}" ]] || beacon_args+=("--enr-address=${node_public_ip}")
    [[ "${genesis_mode}" == false ]] && beacon_args+=("--checkpoint-sync-url=${checkpoint_url}")
    if [[ "${#bootstrap_args[@]}" -gt 0 ]]; then
        lighthouse_bootnodes="$(IFS=,; echo "${bootstrap_args[*]}")"
        beacon_args+=("--boot-nodes=${lighthouse_bootnodes}")
    fi
    docker run -d \
        --name "${beacon_container}" \
        --label "io.abpos.chain=${chain_name}" \
        --label "io.abpos.network=${network}" \
        --label "io.abpos.role=consensus" \
        --label "io.abpos.consensus-client=${consensus_client}" \
        --restart unless-stopped --network host \
        -v "${beacon_data_dir}:/data" -v "${share_dir}:/share:ro" \
        -v "${lighthouse_network_dir}:/node-network" \
        -v "${jwt_secret_file}:/jwtsecret:ro" \
        "${default_lighthouse_image}" "${beacon_args[@]}" >/dev/null
    persist_generated_lighthouse_network_identity
fi

function import_prysm_keys() {
    local import_log
    local import_status=0

    if ! validator_key_import_required; then
        return 0
    fi
    if [[ ! -f "${validator_data_dir}/direct/accounts/all-accounts.keystore.json" ]]; then
        docker run --rm \
            -v "${validator_data_dir}:/wallet" \
            -v "${password_file}:/password.txt:ro" \
            "${default_prysm_validator_image}" \
            wallet create --accept-terms-of-use=true \
            --wallet-dir=/wallet --wallet-password-file=/password.txt \
            --keymanager-kind=imported
    fi
    import_log="$(mktemp "${data_dir}/prysm-import.XXXXXX")"
    docker run --rm \
        -v "${validator_data_dir}:/wallet" \
        -v "${keys_dir}:/keys:ro" \
        -v "${password_file}:/password.txt:ro" \
        "${default_prysm_validator_image}" \
        accounts import --accept-terms-of-use=true \
        --wallet-dir=/wallet --wallet-password-file=/password.txt \
        --account-password-file=/password.txt --keys-dir=/keys \
        >"${import_log}" 2>&1 || import_status=$?
    cat "${import_log}"
    if (( import_status != 0 )); then
        if prysm_import_was_duplicate_only "${import_log}"; then
            color "33" "All supplied Prysm validator keys were already imported."
        else
            rm -f -- "${import_log}"
            return "${import_status}"
        fi
    fi
    rm -f -- "${import_log}"
}

function import_lighthouse_keys() {
    if ! validator_key_import_required; then
        return 0
    fi
    docker run --rm \
        -v "${validator_data_dir}:/validator-data" \
        -v "${share_dir}:/share:ro" \
        -v "${keys_dir}:/keys:ro" \
        -v "${password_file}:/password.txt:ro" \
        "${default_lighthouse_image}" \
        lighthouse account validator import \
        --testnet-dir=/share --datadir=/validator-data \
        --directory=/keys --reuse-password --password-file=/password.txt
}

if [[ "${validator_mode}" == true ]]; then
    replace_role_containers validator \
        "${data_dir}/prysm-validator" "${data_dir}/lighthouse-validator"
    if [[ "${consensus_client}" == "prysm" ]]; then
        import_prysm_keys
        docker run -d \
            --name "${validator_container}" \
            --label "io.abpos.chain=${chain_name}" \
            --label "io.abpos.network=${network}" \
            --label "io.abpos.role=validator" \
            --label "io.abpos.consensus-client=${consensus_client}" \
            --restart unless-stopped --network host \
            -v "${validator_data_dir}:/wallet" \
            -v "${share_dir}:/share:ro" \
            -v "${password_file}:/password.txt:ro" \
            "${default_prysm_validator_image}" \
            --accept-terms-of-use=true \
            --datadir=/wallet \
            --chain-config-file=/share/config.prysm.yaml \
            --beacon-rpc-provider=127.0.0.1:4000 \
            --wallet-dir=/wallet --wallet-password-file=/password.txt \
            "--suggested-fee-recipient=${fee_recipient}" \
            "${validator_metadata_args[@]}" >/dev/null
    else
        import_lighthouse_keys
        docker run -d \
            --name "${validator_container}" \
            --label "io.abpos.chain=${chain_name}" \
            --label "io.abpos.network=${network}" \
            --label "io.abpos.role=validator" \
            --label "io.abpos.consensus-client=${consensus_client}" \
            --restart unless-stopped --network host \
            -v "${validator_data_dir}:/validator-data" \
            -v "${share_dir}:/share:ro" \
            "${default_lighthouse_image}" \
            lighthouse vc --testnet-dir=/share --datadir=/validator-data \
            --beacon-nodes=http://127.0.0.1:3500 \
            "--suggested-fee-recipient=${fee_recipient}" \
            --init-slashing-protection \
            "${validator_metadata_args[@]}" >/dev/null
    fi
fi

color "32" "AB PoS node installation completed."
color "37" "Chain: ${chain_name}"
color "37" "Network: ${network}"
color "37" "Consensus client: ${consensus_client}"
color "37" "Execution client: geth"
color "37" "Execution image: ${geth_image}"
color "37" "Data directory: ${data_dir}"
color "37" "Synchronization source: $([[ "${genesis_mode}" == true ]] && echo genesis || echo checkpoint)"
show_docker_status true
show_genesis_node_information
