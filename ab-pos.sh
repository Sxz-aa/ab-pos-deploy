#!/usr/bin/env bash

set -euo pipefail

# Install and operate an AB PoS node with Docker.

readonly script_version="0.1.0"
readonly default_release_repo="${ABPOS_RELEASE_REPO:-abdaodev/ab-pos-deploy}"
readonly default_root_dir="${ABPOS_ROOT_DIR:-/data/abpos}"
readonly default_geth_image="${GETH_DOCKER_IMAGE:-ghcr.io/abdaodev/ab-geth:latest}"
readonly default_prysm_beacon_image="${PRYSM_BEACON_IMAGE:-offchainlabs/prysm-beacon-chain:stable}"
readonly default_prysm_validator_image="${PRYSM_VALIDATOR_IMAGE:-offchainlabs/prysm-validator:stable}"
readonly default_lighthouse_image="${LIGHTHOUSE_IMAGE:-sigp/lighthouse:latest}"
readonly default_deposit_cli_image="${DEPOSIT_CLI_IMAGE:-ghcr.io/ethstaker/ethstaker-deposit-cli:latest}"

function color() {
    printf '\033[%sm%s\033[0m\n' "$@"
}

function fail() {
    color "31" "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<'USAGE'
AB PoS Docker installer.

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
  --keys-dir PATH                Default: <root-dir>/keys/validator_keys
  --password-file PATH           Default: <root-dir>/keys/pwd.txt
  --docker                       Docker deployment; currently the default
  --binary                       Reserved and not implemented
  --yes                          Skip non-destructive confirmation prompts
  -h, --help                     Show this help
  --version                      Show script version

Operations:
  --status                       Show containers and synchronization state
  --logs [geth|beacon|validator] Follow logs
  --stop                         Stop this node
  --restart                      Restart this node

Examples:
  ./ab-pos.sh testnet prysm geth

  ./ab-pos.sh testnet prysm geth \
    --genesis --validator \
    --fee-recipient 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332 \

  ./ab-pos.sh testnet lighthouse geth \
    --validator \
    --withdrawal-address 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332 \
    --fee-recipient 0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332
USAGE
}

function require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
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

function copy_release_file() {
    local source_root="$1"
    local file_name="$2"
    local required="${3:-true}"
    local source_file

    source_file="$(find "${source_root}" -type f -name "${file_name}" -print -quit)"
    if [[ -z "${source_file}" ]]; then
        [[ "${required}" == "false" ]] && return 0
        fail "Release does not contain ${file_name}."
    fi
    install -m 644 "${source_file}" "${share_dir}/${file_name}"
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
        --docker) ;;
        --binary) fail "Binary deployment is not implemented yet." ;;
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
        keys_dir="${root_dir}/keys/validator_keys"
    fi
fi
password_file="${password_file:-$(dirname "${keys_dir}")/pwd.txt}"
share_dir="${data_dir}/share"
geth_data_dir="${data_dir}/geth"
beacon_data_dir="${data_dir}/${consensus_client}"
validator_data_dir="${data_dir}/${consensus_client}-validator"
mnemonic_file="$(dirname "${password_file}")/mnemonic.txt"
deposit_cli_image="${default_deposit_cli_image}"

container_prefix="abpos-${network}"
geth_container="${container_prefix}-geth"
beacon_container="${container_prefix}-${consensus_client}"
validator_container="${container_prefix}-${consensus_client}-validator"

function container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

function show_status() {
    docker ps -a --filter "name=^/${container_prefix}-" \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    printf '\nBeacon synchronization:\n'
    curl -fsS --max-time 5 http://127.0.0.1:3500/eth/v1/node/syncing 2>/dev/null | jq . || true
    printf '\nBeacon peers:\n'
    curl -fsS --max-time 5 http://127.0.0.1:3500/eth/v1/node/peer_count 2>/dev/null | jq . || true
    printf '\nFinality:\n'
    curl -fsS --max-time 5 http://127.0.0.1:3500/eth/v1/beacon/states/head/finality_checkpoints 2>/dev/null | jq . || true
}

function operate_existing_node() {
    case "${operation}" in
        status) show_status ;;
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

require_command docker

if [[ "${operation}" != "install" ]]; then
    require_command curl
    require_command jq
    operate_existing_node
    exit 0
fi

require_command curl
require_command find
require_command jq
require_command openssl
require_command sha256sum
require_command tar

docker info >/dev/null 2>&1 || fail "Docker is unavailable or permission was denied."

if [[ "${validator_mode}" == true ]]; then
    [[ -n "${fee_recipient}" ]] || fail "--fee-recipient is required with --validator."
    require_address "fee recipient" "${fee_recipient}"
fi

if [[ "${validator_mode}" == true && "${genesis_mode}" == false ]]; then
    [[ -n "${withdrawal_address}" ]] || fail "--withdrawal-address is required for a non-genesis validator."
    require_address "withdrawal address" "${withdrawal_address}"
fi

mkdir -p "${share_dir}" "${geth_data_dir}" "${beacon_data_dir}" "${validator_data_dir}" "${keys_dir}"

function resolve_release() {
    local api_url="https://api.github.com/repos/${release_repo}/releases"
    local release_json
    local asset_url

    if [[ -n "${release_url}" ]]; then
        printf '%s\n' "${release_url}"
        return
    fi

    if [[ "${release_version}" == "latest" ]]; then
        release_json="$(curl -fsSL "${api_url}/latest")" || fail "Unable to query the latest Release."
    else
        release_json="$(curl -fsSL "${api_url}/tags/${release_version}")" || fail "Unable to query Release ${release_version}."
    fi

    asset_url="$(
        jq -r --arg network "${network}" '
            [.assets[] | select(.name | test($network; "i")) | select(.name | endswith(".tar.gz"))][0].browser_download_url // empty
        ' <<<"${release_json}"
    )"
    [[ -n "${asset_url}" ]] || fail "No ${network} .tar.gz asset was found in the selected Release."
    printf '%s\n' "${asset_url}"
}

function download_release() {
    local selected_url
    local archive_path
    local checksum_url
    local checksum_path
    local extract_dir

    selected_url="$(resolve_release)"
    archive_path="${data_dir}/$(basename "${selected_url%%\?*}")"
    checksum_url="${selected_url}.sha256"
    checksum_path="${archive_path}.sha256"
    extract_dir="$(mktemp -d "${data_dir}/release.XXXXXX")"

    color "34" "Downloading network Release: ${selected_url}"
    curl -fL "${selected_url}" -o "${archive_path}"

    if curl -fsSL "${checksum_url}" -o "${checksum_path}"; then
        (
            cd "$(dirname "${archive_path}")"
            sha256sum -c "$(basename "${checksum_path}")"
        ) || fail "Release checksum verification failed."
    else
        color "33" "Release checksum asset was not found; continuing without checksum verification."
    fi

    tar -xzf "${archive_path}" -C "${extract_dir}"
    copy_release_file "${extract_dir}" genesis.json
    copy_release_file "${extract_dir}" genesis.ssz
    copy_release_file "${extract_dir}" jwtsecret
    copy_release_file "${extract_dir}" config.yaml
    copy_release_file "${extract_dir}" config.prysm.yaml
    copy_release_file "${extract_dir}" bootstrap_nodes.txt false
    copy_release_file "${extract_dir}" enodes.txt false
    copy_release_file "${extract_dir}" checkpoint_sync_urls.txt false
    rm -rf -- "${extract_dir}"
}

if [[ ! -s "${share_dir}/genesis.json" || ! -s "${share_dir}/genesis.ssz" ]]; then
    download_release
else
    color "33" "Using existing network configuration in ${share_dir}."
fi

for required_file in genesis.json genesis.ssz jwtsecret config.yaml config.prysm.yaml; do
    [[ -s "${share_dir}/${required_file}" ]] || fail "Missing required file: ${share_dir}/${required_file}"
done

if [[ "${genesis_mode}" == false && -z "${checkpoint_url}" ]]; then
    checkpoint_url="$(first_data_line "${share_dir}/checkpoint_sync_urls.txt")"
    [[ -n "${checkpoint_url}" ]] || fail "A non-genesis node requires --checkpoint-url or checkpoint_sync_urls.txt."
fi

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

    mkdir -p "${keys_parent}" "${keys_dir}"
    chmod 700 "${keys_parent}" "${keys_dir}"
    umask 077

    if [[ ! -s "${password_file}" ]]; then
        openssl rand -hex 32 >"${password_file}"
        chmod 600 "${password_file}"
    fi

    if [[ ! -s "${mnemonic_file}" ]]; then
        docker run --rm --tty --env TERM=xterm \
            --user "${host_uid}:${host_gid}" \
            -v "${keys_parent}:/app/keys" \
            "${deposit_cli_image}" \
            --non_interactive --ignore_connectivity --language english \
            generate-mnemonic \
            --mnemonic_language=english \
            --output_file=/app/keys/mnemonic.txt
        chmod 600 "${mnemonic_file}"
    fi

    mnemonic="$(<"${mnemonic_file}")"
    password="$(<"${password_file}")"
    devnet_setting='{"network_name":"abcore","genesis_fork_version":"0x000001ab","exit_fork_version":"0x000001ab","genesis_validator_root":"0x0000000000000000000000000000000000000000000000000000000000000000","multiplier":1,"min_activation_amount":32,"min_deposit_amount":1}'

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
if [[ -f "${share_dir}/enodes.txt" ]]; then
    bootnodes="$(sed -e 's/\r$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "${share_dir}/enodes.txt" | paste -sd, -)"
fi

if [[ ! -d "${geth_data_dir}/geth/chaindata" ]]; then
    color "34" "Initializing Geth from genesis.json."
    docker run --rm \
        -v "${geth_data_dir}:/data" \
        -v "${share_dir}:/share:ro" \
        "${default_geth_image}" \
        --datadir=/data init /share/genesis.json
fi

docker rm -f "${geth_container}" >/dev/null 2>&1 || true
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
    --authrpc.jwtsecret=/share/jwtsecret
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
    "${default_geth_image}" "${geth_args[@]}" >/dev/null

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
        --jwt-secret=/share/jwtsecret
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
        "${default_prysm_beacon_image}" "${beacon_args[@]}" >/dev/null
else
    beacon_args=(
        lighthouse bn
        --testnet-dir=/share
        --datadir=/data
        --execution-endpoint=http://127.0.0.1:8551
        --execution-jwt=/share/jwtsecret
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
color "37" "Data directory: ${data_dir}"
color "37" "Synchronization source: $([[ "${genesis_mode}" == true ]] && echo genesis || echo checkpoint)"
show_status
