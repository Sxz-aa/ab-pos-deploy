#!/usr/bin/env bash

set -euo pipefail

# Install and operate an AB PoS node with Docker or native binaries.

readonly script_version="0.2.0"
readonly default_release_repo="${ABPOS_RELEASE_REPO:-abdaodev/ab-pos-deploy}"
readonly default_root_dir="${ABPOS_ROOT_DIR:-/data/abpos}"
readonly github_api_url="${GITHUB_API_URL:-https://api.github.com}"
readonly geth_image_override="${GETH_DOCKER_IMAGE:-}"
readonly default_prysm_beacon_image="${PRYSM_BEACON_IMAGE:-offchainlabs/prysm-beacon-chain:stable}"
readonly default_prysm_validator_image="${PRYSM_VALIDATOR_IMAGE:-offchainlabs/prysm-validator:stable}"
readonly default_lighthouse_image="${LIGHTHOUSE_IMAGE:-sigp/lighthouse:latest}"
readonly default_deposit_cli_image="${DEPOSIT_CLI_IMAGE:-ghcr.io/ethstaker/ethstaker-deposit-cli:latest}"
readonly geth_binary_url_override="${AB_GETH_BINARY_URL:-}"
readonly geth_binary_checksum_url_override="${AB_GETH_BINARY_SHA256_URL:-}"
readonly prysm_release_version="${PRYSM_RELEASE_VERSION:-latest}"
readonly lighthouse_release_version="${LIGHTHOUSE_RELEASE_VERSION:-latest}"
readonly deposit_cli_release_version="${DEPOSIT_CLI_RELEASE_VERSION:-latest}"

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
  ab-pos.sh <network> <consensus-client> geth [options]
  ab-pos.sh <network> <consensus-client> geth --status
  ab-pos.sh <network> <consensus-client> geth --logs [service]
  ab-pos.sh <network> <consensus-client> geth --stop
  ab-pos.sh <network> <consensus-client> geth --restart

Arguments:
  network             testnet or mainnet
  consensus-client    prysm or lighthouse
  execution-client    geth

Node modes:
  Default              RPC node, synchronized from checkpoint
  --validator          Validator node, synchronized from checkpoint
  --genesis            Synchronize from genesis instead of checkpoint
  --archive            Run Geth in archive mode

Validator behavior:
  --genesis --validator
      Import existing validator keys. Keys are never generated in this mode.

  --validator
      Generate a new mnemonic and validator keys when the key directory is
      empty, then import them. The generated deposit data must still be
      submitted before the validators can become active.

Core options:
  --withdrawal-address ADDRESS   Required when generating new validator keys
  --fee-recipient ADDRESS        Required for a validator node
  --validator-count NUMBER       Default: 1000
  --checkpoint-url URL           Override the Release checkpoint URL
  --release VERSION              Release tag; default: latest
  --release-repo OWNER/REPO      Default: abdaodev/ab-pos-deploy
  --release-url URL              Download a specific .tar.gz Release archive
  --root-dir PATH                Default: /data/abpos
  --data-dir PATH                Default: <root-dir>/<network>
  --keys-dir PATH                Override the mode-specific key directory
  --password-file PATH           Override the password file beside the keys
  --docker                       Deploy containers; default
  --binary                       Deploy downloaded native binaries
  --yes                          Skip non-destructive confirmation prompts
  -h, --help                     Show this help
  --version                      Show script version

Operations:
  --status                       Show services and synchronization state
  --logs [geth|beacon|validator] Follow logs
  --stop                         Stop this node
  --restart                      Restart this node

Examples:
  ./ab-pos.sh testnet prysm geth

  ./ab-pos.sh testnet prysm geth \
    --genesis --validator \
    --fee-recipient 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332

  ./ab-pos.sh testnet lighthouse geth \
    --validator \
    --withdrawal-address 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332 \
    --fee-recipient 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332
USAGE
}

function require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
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

    for command_name in install sha256sum; do
        command -v "${command_name}" >/dev/null 2>&1 || needs_coreutils=true
    done
    [[ "${needs_coreutils}" == false ]] || packages+=(coreutils)

    if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        packages+=(ca-certificates)
    fi

    if [[ "${deployment_mode}" == "docker" ]]; then
        command -v docker >/dev/null 2>&1 || packages+=(docker.io)
    else
        command -v setsid >/dev/null 2>&1 || packages+=(util-linux)
    fi

    (( ${#packages[@]} > 0 )) || return
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
    [[ "${value}" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "Invalid ${name}: ${value}"
}

function first_data_line() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${file}" | head -n 1
}

network=""
consensus_client=""
execution_client=""
genesis_mode=false
validator_mode=false
archive_mode=false
operation="install"
log_service=""
withdrawal_address=""
fee_recipient=""
checkpoint_url=""
release_version="latest"
release_repo="${default_release_repo}"
release_url=""
network_release_url=""
geth_asset_name=""
geth_asset_url=""
geth_checksum_url=""
resolved_geth_version=""
geth_image=""
platform_arch=""
deployment_mode="docker"
deployment_mode_selected=false
root_dir="${default_root_dir}"
data_dir=""
keys_dir=""
password_file=""
validator_count="1000"
assume_yes=false

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--version" ]]; then
    printf '%s\n' "${script_version}"
    exit 0
fi

[[ "$#" -ge 3 ]] || {
    usage >&2
    exit 1
}

network="${1,,}"
consensus_client="${2,,}"
execution_client="${3,,}"
shift 3

case "${network}" in
    test | testnet) network="testnet" ;;
    main | mainnet) network="mainnet" ;;
    *) fail "Unsupported network: ${network}" ;;
esac

case "${consensus_client}" in
    prysm | lighthouse) ;;
    *) fail "Unsupported consensus client: ${consensus_client}" ;;
esac

[[ "${execution_client}" == "geth" ]] || fail "Unsupported execution client: ${execution_client}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --genesis) genesis_mode=true ;;
        --validator) validator_mode=true ;;
        --archive) archive_mode=true ;;
        --withdrawal-address) withdrawal_address="${2:-}"; shift ;;
        --fee-recipient) fee_recipient="${2:-}"; shift ;;
        --validator-count) validator_count="${2:-}"; shift ;;
        --checkpoint-url) checkpoint_url="${2:-}"; shift ;;
        --release) release_version="${2:-}"; shift ;;
        --release-repo) release_repo="${2:-}"; shift ;;
        --release-url) release_url="${2:-}"; shift ;;
        --root-dir) root_dir="${2:-}"; shift ;;
        --data-dir) data_dir="${2:-}"; shift ;;
        --keys-dir) keys_dir="${2:-}"; shift ;;
        --password-file) password_file="${2:-}"; shift ;;
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

[[ "${validator_count}" =~ ^[1-9][0-9]*$ ]] || fail "Validator count must be a positive integer."
[[ "${release_repo}" =~ ^[^/]+/[^/]+$ ]] || fail "Release repository must use OWNER/REPO format."

data_dir="${data_dir:-${root_dir}/${network}}"
if [[ -z "${keys_dir}" ]]; then
    if [[ "${validator_mode}" == true && "${genesis_mode}" == false ]]; then
        keys_dir="${data_dir}/validator-keys"
    else
        keys_dir="${data_dir}/keys/validator_keys"
    fi
fi
password_file="${password_file:-$(dirname "${keys_dir}")/pwd.txt}"
share_dir="${data_dir}/share"
geth_data_dir="${data_dir}/geth"
beacon_data_dir="${data_dir}/${consensus_client}"
validator_data_dir="${data_dir}/${consensus_client}-validator"
mnemonic_file="$(dirname "${password_file}")/mnemonic.txt"
deposit_cli_image="${default_deposit_cli_image}"
jwt_secret_file="${data_dir}/jwtsecret"
bin_dir="${data_dir}/bin"
run_dir="${data_dir}/run"
log_dir="${data_dir}/logs"

container_prefix="abpos-${network}"
geth_container="${container_prefix}-geth"
beacon_container="${container_prefix}-${consensus_client}"
validator_container="${container_prefix}-${consensus_client}-validator"

function container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

function show_sync_status() {
    printf '\nBeacon synchronization:\n'
    curl -fsS --max-time 5 http://127.0.0.1:3500/eth/v1/node/syncing 2>/dev/null | jq . || true
    printf '\nBeacon peers:\n'
    curl -fsS --max-time 5 http://127.0.0.1:3500/eth/v1/node/peer_count 2>/dev/null | jq . || true
    printf '\nFinality:\n'
    curl -fsS --max-time 5 http://127.0.0.1:3500/eth/v1/beacon/states/head/finality_checkpoints 2>/dev/null | jq . || true
}

function show_docker_status() {
    docker ps -a --filter "name=^/${container_prefix}-" \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    show_sync_status
}

function operate_existing_docker_node() {
    case "${operation}" in
        status) show_docker_status ;;
        stop)
            docker stop "${validator_container}" "${beacon_container}" "${geth_container}" 2>/dev/null || true
            ;;
        restart)
            docker restart "${geth_container}" "${beacon_container}" 2>/dev/null || true
            if container_exists "${validator_container}"; then
                docker restart "${validator_container}"
            fi
            ;;
        logs)
            case "${log_service:-beacon}" in
                geth) docker logs -f --tail 200 "${geth_container}" ;;
                beacon | prysm | lighthouse) docker logs -f --tail 200 "${beacon_container}" ;;
                validator) docker logs -f --tail 200 "${validator_container}" ;;
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
    local service
    local pid_file
    local pid

    printf '%-12s %-8s %s\n' SERVICE PID STATUS
    for service in geth beacon validator; do
        pid_file="$(binary_pid_file "${service}")"
        pid="-"
        [[ -s "${pid_file}" ]] && pid="$(<"${pid_file}")"
        if binary_service_running "${service}"; then
            printf '%-12s %-8s %s\n' "${service}" "${pid}" running
        elif [[ -x "$(binary_launcher_file "${service}")" ]]; then
            printf '%-12s %-8s %s\n' "${service}" "${pid}" stopped
        fi
    done
    show_sync_status
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

if [[ "${operation}" != "install" ]]; then
    require_command curl
    require_command jq
    if [[ "${deployment_mode}" == "docker" ]]; then
        require_command docker
        operate_existing_docker_node
    else
        require_command setsid
        operate_existing_binary_node
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
else
    require_command setsid
fi

if [[ "${validator_mode}" == true ]]; then
    [[ -n "${fee_recipient}" ]] || fail "--fee-recipient is required with --validator."
    require_address "fee recipient" "${fee_recipient}"
fi

if [[ "${validator_mode}" == true && "${genesis_mode}" == false ]]; then
    [[ -n "${withdrawal_address}" ]] || fail "--withdrawal-address is required for a non-genesis validator."
    require_address "withdrawal address" "${withdrawal_address}"
fi

mkdir -p "${share_dir}" "${geth_data_dir}" "${beacon_data_dir}" "${validator_data_dir}" \
    "${keys_dir}" "${bin_dir}" "${run_dir}" "${log_dir}"

function ensure_local_jwt_secret() {
    local jwt
    local temporary_file

    if [[ ! -s "${jwt_secret_file}" ]]; then
        temporary_file="$(mktemp "${data_dir}/.jwtsecret.XXXXXX")"
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

ensure_local_jwt_secret

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
        fi
        return
    fi

    if [[ "${release_version}" == "latest" ]]; then
        release_json="$(curl -fsSL "${api_url}/latest")" || fail "Unable to query the latest Release."
    else
        release_json="$(curl -fsSL "${api_url}/tags/${release_version}")" || fail "Unable to query Release ${release_version}."
    fi

    network_asset_count="$(
        jq -r --arg prefix "abpos-${network}-" '
            [.assets[] | select(.name | startswith($prefix)) | select(.name | endswith(".tar.gz"))] | length
        ' <<<"${release_json}"
    )"
    [[ "${network_asset_count}" -eq 1 ]] \
        || fail "The selected Release must contain exactly one ${network} network archive; found ${network_asset_count}."
    network_release_url="$(
        jq -r --arg prefix "abpos-${network}-" '
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

    if [[ "${deployment_mode}" == "docker" ]]; then
        release_owner="${release_repo%%/*}"
        geth_image="${geth_image_override:-ghcr.io/${release_owner,,}/ab-geth:${resolved_geth_version}}"
    fi
}

function download_release() {
    local archive_path
    local archive_listing
    local checksum_url
    local checksum_path
    local previous_share_dir
    local required_file
    local temporary_share_dir
    local member
    local normalized_member

    archive_path="${PWD}/$(basename "${network_release_url%%\?*}")"
    archive_listing="${archive_path}.contents"
    checksum_url="${network_release_url}.sha256"
    checksum_path="${archive_path}.sha256"

    color "34" "Downloading network Release: ${network_release_url}"
    curl -fL "${network_release_url}" -o "${archive_path}"

    if curl -fsSL "${checksum_url}" -o "${checksum_path}"; then
        (
            cd "$(dirname "${archive_path}")"
            sha256sum -c "$(basename "${checksum_path}")"
        ) || fail "Release checksum verification failed."
    else
        color "33" "Release checksum asset was not found; continuing without checksum verification."
    fi

    tar -tzf "${archive_path}" > "${archive_listing}" \
        || fail "Unable to inspect the network Release archive."
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
        deposit_contract_block.txt bootstrap_nodes.txt bootstrap_nodes_execution.txt; do
        if [[ ! -s "${temporary_share_dir}/${required_file}" ]]; then
            rm -rf -- "${temporary_share_dir}"
            fail "The network Release is missing required file: ${required_file}"
        fi
    done

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

resolve_release
download_release

for required_file in genesis.json genesis.ssz config.yaml config.prysm.yaml \
    deposit_contract_block.txt bootstrap_nodes.txt bootstrap_nodes_execution.txt; do
    [[ -s "${share_dir}/${required_file}" ]] || fail "Missing required file: ${share_dir}/${required_file}"
done

if [[ "${genesis_mode}" == false && -z "${checkpoint_url}" ]]; then
    checkpoint_url="$(first_data_line "${share_dir}/checkpoint_sync_urls.txt")"
    [[ -n "${checkpoint_url}" ]] || fail "A non-genesis node requires --checkpoint-url or checkpoint_sync_urls.txt."
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
    local keystore_count
    local mnemonic
    local password
    local devnet_setting

    keys_parent="$(dirname "${keys_dir}")"
    host_uid="${SUDO_UID:-$(id -u)}"
    host_gid="${SUDO_GID:-$(id -g)}"
    keystore_count="$(find "${keys_dir}" -maxdepth 1 -type f -name 'keystore-*.json' | wc -l | tr -d ' ')"

    if [[ "${keystore_count}" -gt 0 ]]; then
        color "33" "Using ${keystore_count} existing validator keystores in ${keys_dir}."
        return
    fi

    if [[ "${deployment_mode}" == "binary" ]]; then
        install_deposit_cli_binary
    else
        require_command docker
        docker info >/dev/null 2>&1 \
            || fail "Docker is required to generate validator keys and is unavailable."
    fi

    mkdir -p "${keys_parent}" "${keys_dir}"
    chmod 700 "${keys_parent}" "${keys_dir}"
    umask 077

    if [[ ! -s "${password_file}" ]]; then
        openssl rand -hex 32 >"${password_file}"
        chmod 600 "${password_file}"
    fi

    if [[ ! -s "${mnemonic_file}" ]]; then
        if [[ "${deployment_mode}" == "binary" ]]; then
            "${bin_dir}/deposit" \
                --non_interactive --ignore_connectivity --language english \
                generate-mnemonic \
                --mnemonic_language=english \
                "--output_file=${mnemonic_file}"
        else
            docker run --rm --tty --env TERM=xterm \
                --user "${host_uid}:${host_gid}" \
                -v "${keys_parent}:/app/keys" \
                "${deposit_cli_image}" \
                --non_interactive --ignore_connectivity --language english \
                generate-mnemonic \
                --mnemonic_language=english \
                --output_file=/app/keys/mnemonic.txt
        fi
        chmod 600 "${mnemonic_file}"
    fi

    mnemonic="$(<"${mnemonic_file}")"
    password="$(<"${password_file}")"
    devnet_setting='{"network_name":"abcore","genesis_fork_version":"0x000001ab","exit_fork_version":"0x000001ab","genesis_validator_root":"0x0000000000000000000000000000000000000000000000000000000000000000","multiplier":1,"min_activation_amount":32,"min_deposit_amount":1}'

    if [[ "${deployment_mode}" == "binary" ]]; then
        local generation_dir
        local generated_keys_dir

        generation_dir="$(mktemp -d "${keys_parent}/deposit-output.XXXXXX")"
        generated_keys_dir="${generation_dir}/validator_keys"
        if ! "${bin_dir}/deposit" \
            --non_interactive --ignore_connectivity --language english \
            existing-mnemonic \
            --mnemonic="${mnemonic}" \
            --keystore_password="${password}" \
            --validator_start_index=0 \
            --num_validators="${validator_count}" \
            --withdrawal_address="${withdrawal_address}" \
            --compounding \
            --amount=2048 \
            --devnet_chain_setting="${devnet_setting}" \
            "--folder=${generation_dir}"; then
            rm -rf -- "${generation_dir}"
            fail "EthStaker Deposit CLI failed to generate validator keys."
        fi
        [[ -d "${generated_keys_dir}" ]] || {
            rm -rf -- "${generation_dir}"
            fail "EthStaker Deposit CLI did not create validator_keys/."
        }
        cp -a "${generated_keys_dir}/." "${keys_dir}/"
        rm -rf -- "${generation_dir}"
    else
        docker run --rm --tty --env TERM=xterm \
            --user "${host_uid}:${host_gid}" \
            -v "${keys_dir}:/app/validator_keys" \
            "${deposit_cli_image}" \
            --non_interactive --ignore_connectivity --language english \
            existing-mnemonic \
            --mnemonic="${mnemonic}" \
            --keystore_password="${password}" \
            --validator_start_index=0 \
            --num_validators="${validator_count}" \
            --withdrawal_address="${withdrawal_address}" \
            --compounding \
            --amount=2048 \
            --devnet_chain_setting="${devnet_setting}" \
            --folder=/app
    fi

    unset mnemonic password
    keystore_count="$(find "${keys_dir}" -maxdepth 1 -type f -name 'keystore-*.json' | wc -l | tr -d ' ')"
    [[ "${keystore_count}" -eq "${validator_count}" ]] || fail "Expected ${validator_count} keystores, found ${keystore_count}."

    color "32" "Generated ${keystore_count} validator keys."
    color "32" "Deposit data: $(find "${keys_dir}" -maxdepth 1 -name 'deposit_data-*.json' -print -quit)"
    color "33" "Submit the deposit data before expecting the validators to activate."
    color "31" "Never share ${mnemonic_file}, ${password_file}, or validator keystores."
}

if [[ "${validator_mode}" == true ]]; then
    if [[ "${genesis_mode}" == true ]]; then
        existing_keys="$(find "${keys_dir}" -maxdepth 1 -type f -name 'keystore-*.json' | wc -l | tr -d ' ')"
        [[ "${existing_keys}" -gt 0 ]] || fail "Genesis validator mode requires existing keystores in ${keys_dir}."
        [[ -s "${password_file}" ]] || fail "Missing validator password file: ${password_file}"
    else
        generate_validator_keys
    fi
fi

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
    local release_json
    local release_tag
    local release_arch
    local asset_name
    local asset_url
    local asset_digest
    local expected_sha256
    local temporary_dir
    local archive
    local extracted_binary

    release_json="$(github_release_json sigp/lighthouse "${lighthouse_release_version}")" \
        || fail "Unable to query the Lighthouse Release."
    release_tag="$(jq -r '.tag_name // empty' <<<"${release_json}")"
    [[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
        || fail "The Lighthouse Release has an invalid tag: ${release_tag:-empty}"
    case "${platform_arch}" in
        amd64) release_arch="x86_64" ;;
        arm64) release_arch="aarch64" ;;
        *) fail "Unsupported Lighthouse architecture: ${platform_arch}" ;;
    esac
    asset_name="lighthouse-${release_tag}-${release_arch}-unknown-linux-gnu.tar.gz"
    asset_url="$(jq -r --arg name "${asset_name}" \
        '[.assets[] | select(.name == $name)][0].browser_download_url // empty' <<<"${release_json}")"
    asset_digest="$(jq -r --arg name "${asset_name}" \
        '[.assets[] | select(.name == $name)][0].digest // empty' <<<"${release_json}")"
    expected_sha256="${asset_digest#sha256:}"
    [[ -n "${asset_url}" && "${asset_digest}" == sha256:* \
        && "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] \
        || fail "Lighthouse Release ${release_tag} does not provide a verifiable ${asset_name}."

    temporary_dir="$(mktemp -d "${data_dir}/lighthouse-download.XXXXXX")"
    archive="${temporary_dir}/${asset_name}"
    if ! curl -fL "${asset_url}" -o "${archive}"; then
        rm -rf -- "${temporary_dir}"
        fail "Unable to download ${asset_name}."
    fi
    if ! printf '%s  %s\n' "${expected_sha256}" "${archive}" | sha256sum -c -; then
        rm -rf -- "${temporary_dir}"
        fail "Checksum verification failed for ${asset_name}."
    fi
    if ! tar -xzf "${archive}" -C "${temporary_dir}"; then
        rm -rf -- "${temporary_dir}"
        fail "Unable to extract ${asset_name}."
    fi
    extracted_binary="$(find "${temporary_dir}" -type f -name lighthouse -print -quit)"
    [[ -n "${extracted_binary}" ]] || {
        rm -rf -- "${temporary_dir}"
        fail "${asset_name} does not contain the Lighthouse binary."
    }
    install -m 0755 "${extracted_binary}" "${bin_dir}/lighthouse.new"
    mv -f -- "${bin_dir}/lighthouse.new" "${bin_dir}/lighthouse"
    rm -rf -- "${temporary_dir}"
    printf '%s\n' "${release_tag}" >"${bin_dir}/lighthouse.version"
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
    if [[ ! -f "${validator_data_dir}/direct/accounts/all-accounts.keystore.json" ]]; then
        "${bin_dir}/prysm-validator" wallet create --accept-terms-of-use=true \
            "--wallet-dir=${validator_data_dir}" "--wallet-password-file=${password_file}" \
            --keymanager-kind=imported
    fi
    "${bin_dir}/prysm-validator" accounts import --accept-terms-of-use=true \
        "--wallet-dir=${validator_data_dir}" "--wallet-password-file=${password_file}" \
        "--account-password-file=${password_file}" "--keys-dir=${keys_dir}"
}

function import_lighthouse_keys_binary() {
    "${bin_dir}/lighthouse" account validator import \
        "--testnet-dir=${share_dir}" "--datadir=${validator_data_dir}" \
        "--directory=${keys_dir}" --reuse-password "--password-file=${password_file}"
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

    if [[ -d "${geth_data_dir}/geth/chaindata" ]]; then
        color "34" "Updating Geth chain configuration from genesis.json."
    else
        color "34" "Initializing Geth from genesis.json."
    fi
    "${bin_dir}/geth" "--datadir=${geth_data_dir}" init "${share_dir}/genesis.json"

    geth_binary_args=(
        "--datadir=${geth_data_dir}"
        "--networkid=${network_id}"
        --port=30303
        --http
        --http.addr=127.0.0.1
        --http.port=8545
        --http.api=eth,net,web3,admin
        --authrpc.addr=127.0.0.1
        --authrpc.port=8551
        --authrpc.vhosts=\*
        "--authrpc.jwtsecret=${jwt_secret_file}"
        --syncmode=full
    )
    [[ "${archive_mode}" == true ]] && geth_binary_args+=(--gcmode=archive)
    [[ -n "${bootnodes}" ]] && geth_binary_args+=("--bootnodes=${bootnodes}")
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
            --execution-endpoint=http://127.0.0.1:8551
            "--execution-jwt=${jwt_secret_file}"
            --http
            --http-address=127.0.0.1
            --http-port=3500
            --port=13000
            --discovery-port=12000
        )
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
                "--chain-config-file=${share_dir}/config.prysm.yaml"
                --beacon-rpc-provider=127.0.0.1:4000
                "--wallet-dir=${validator_data_dir}"
                "--wallet-password-file=${password_file}"
                "--suggested-fee-recipient=${fee_recipient}"
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
            )
            write_binary_launcher validator "${bin_dir}/lighthouse" "${validator_binary_args[@]}"
        fi
    fi

    start_binary_service geth
    start_binary_service beacon
    if [[ "${validator_mode}" == true ]]; then
        start_binary_service validator
    fi
}

if [[ "${deployment_mode}" == "binary" ]]; then
    deploy_binary_node
    color "32" "AB PoS node installation completed."
    color "37" "Network: ${network}"
    color "37" "Consensus client: ${consensus_client}"
    color "37" "Execution client: geth"
    color "37" "Deployment: native binaries"
    color "37" "Binary directory: ${bin_dir}"
    color "37" "Data directory: ${data_dir}"
    color "37" "Synchronization source: $([[ "${genesis_mode}" == true ]] && echo genesis || echo checkpoint)"
    show_binary_status
    exit 0
fi

docker rm -f "${geth_container}" >/dev/null 2>&1 || true
if [[ -d "${geth_data_dir}/geth/chaindata" ]]; then
    color "34" "Updating Geth chain configuration from genesis.json."
else
    color "34" "Initializing Geth from genesis.json."
fi
docker run --rm \
    -v "${geth_data_dir}:/data" \
    -v "${share_dir}:/share:ro" \
    "${geth_image}" \
    --datadir=/data init /share/genesis.json
geth_args=(
    --datadir=/data
    "--networkid=${network_id}"
    --port=30303
    --http
    --http.addr=127.0.0.1
    --http.port=8545
    --http.api=eth,net,web3,admin
    --authrpc.addr=127.0.0.1
    --authrpc.port=8551
    --authrpc.vhosts=\*
    --authrpc.jwtsecret=/jwtsecret
)
if [[ "${archive_mode}" == true ]]; then
    geth_args+=(--syncmode=full --gcmode=archive)
else
    geth_args+=(--syncmode=full)
fi
[[ -n "${bootnodes}" ]] && geth_args+=("--bootnodes=${bootnodes}")

docker run -d \
    --name "${geth_container}" \
    --restart unless-stopped \
    --network host \
    -v "${geth_data_dir}:/data" \
    -v "${share_dir}:/share:ro" \
    -v "${jwt_secret_file}:/jwtsecret:ro" \
    "${geth_image}" "${geth_args[@]}" >/dev/null

mapfile -t bootstrap_args < <(
    if [[ -f "${share_dir}/bootstrap_nodes.txt" ]]; then
        sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${share_dir}/bootstrap_nodes.txt"
    fi
)

docker rm -f "${beacon_container}" >/dev/null 2>&1 || true
if [[ "${consensus_client}" == "prysm" ]]; then
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
    [[ "${genesis_mode}" == false ]] && beacon_args+=("--checkpoint-sync-url=${checkpoint_url}")
    for enr in "${bootstrap_args[@]}"; do
        beacon_args+=("--bootstrap-node=${enr}")
    done
    docker run -d \
        --name "${beacon_container}" --restart unless-stopped --network host \
        -v "${beacon_data_dir}:/data" -v "${share_dir}:/share:ro" \
        -v "${jwt_secret_file}:/jwtsecret:ro" \
        "${default_prysm_beacon_image}" "${beacon_args[@]}" >/dev/null
else
    beacon_args=(
        lighthouse bn
        --testnet-dir=/share
        --datadir=/data
        --execution-endpoint=http://127.0.0.1:8551
        --execution-jwt=/jwtsecret
        --http
        --http-address=127.0.0.1
        --http-port=3500
        --port=13000
        --discovery-port=12000
    )
    [[ "${genesis_mode}" == false ]] && beacon_args+=("--checkpoint-sync-url=${checkpoint_url}")
    if [[ "${#bootstrap_args[@]}" -gt 0 ]]; then
        lighthouse_bootnodes="$(IFS=,; echo "${bootstrap_args[*]}")"
        beacon_args+=("--boot-nodes=${lighthouse_bootnodes}")
    fi
    docker run -d \
        --name "${beacon_container}" --restart unless-stopped --network host \
        -v "${beacon_data_dir}:/data" -v "${share_dir}:/share:ro" \
        -v "${jwt_secret_file}:/jwtsecret:ro" \
        "${default_lighthouse_image}" "${beacon_args[@]}" >/dev/null
fi

function import_prysm_keys() {
    if [[ ! -f "${validator_data_dir}/direct/accounts/all-accounts.keystore.json" ]]; then
        docker run --rm \
            -v "${validator_data_dir}:/wallet" \
            -v "${password_file}:/password.txt:ro" \
            "${default_prysm_validator_image}" \
            wallet create --accept-terms-of-use=true \
            --wallet-dir=/wallet --wallet-password-file=/password.txt \
            --keymanager-kind=imported
    fi
    docker run --rm \
        -v "${validator_data_dir}:/wallet" \
        -v "${keys_dir}:/keys:ro" \
        -v "${password_file}:/password.txt:ro" \
        "${default_prysm_validator_image}" \
        accounts import --accept-terms-of-use=true \
        --wallet-dir=/wallet --wallet-password-file=/password.txt \
        --account-password-file=/password.txt --keys-dir=/keys
}

function import_lighthouse_keys() {
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
    docker rm -f "${validator_container}" >/dev/null 2>&1 || true
    if [[ "${consensus_client}" == "prysm" ]]; then
        import_prysm_keys
        docker run -d \
            --name "${validator_container}" --restart unless-stopped --network host \
            -v "${validator_data_dir}:/wallet" \
            -v "${share_dir}:/share:ro" \
            -v "${password_file}:/password.txt:ro" \
            "${default_prysm_validator_image}" \
            --accept-terms-of-use=true \
            --chain-config-file=/share/config.prysm.yaml \
            --beacon-rpc-provider=127.0.0.1:4000 \
            --wallet-dir=/wallet --wallet-password-file=/password.txt \
            "--suggested-fee-recipient=${fee_recipient}" >/dev/null
    else
        import_lighthouse_keys
        docker run -d \
            --name "${validator_container}" --restart unless-stopped --network host \
            -v "${validator_data_dir}:/validator-data" \
            -v "${share_dir}:/share:ro" \
            "${default_lighthouse_image}" \
            lighthouse vc --testnet-dir=/share --datadir=/validator-data \
            --beacon-nodes=http://127.0.0.1:3500 \
            "--suggested-fee-recipient=${fee_recipient}" \
            --init-slashing-protection >/dev/null
    fi
fi

color "32" "AB PoS node installation completed."
color "37" "Network: ${network}"
color "37" "Consensus client: ${consensus_client}"
color "37" "Execution client: geth"
color "37" "Execution image: ${geth_image}"
color "37" "Data directory: ${data_dir}"
color "37" "Synchronization source: $([[ "${genesis_mode}" == true ]] && echo genesis || echo checkpoint)"
show_docker_status
