#!/usr/bin/env bash

set -euo pipefail

# Generate AB PoS genesis validator keys and deposit data from reviewed public
# network settings supplied by the Network Operator.

validator_count="${VALIDATOR_COUNT:-1000}"
readonly validator_start_index=0
readonly host_uid="${SUDO_UID:-$(id -u)}"
readonly host_gid="${SUDO_GID:-$(id -g)}"
readonly deposit_cli_image="${DEPOSIT_CLI_IMAGE:-ghcr.io/ethstaker/ethstaker-deposit-cli:latest}"
readonly deposit_cli_release_version="${DEPOSIT_CLI_RELEASE_VERSION:-latest}"
readonly github_api_url="${GITHUB_API_URL:-https://api.github.com}"
readonly default_release_repo="${ABPOS_RELEASE_REPO:-abdaodev/ab-pos-deploy}"
readonly gwei_per_token=1000000000
readonly max_exact_integer=9007199254740991

deployment_mode="docker"
deployment_mode_selected=false
platform_arch=""
deposit_settings_file="${DEPOSIT_SETTINGS_FILE:-}"
settings_release=""
settings_release_repo="${default_release_repo}"
settings_release_url=""
settings_download_dir=""
deposit_amount="${VALIDATOR_DEPOSIT_AMOUNT:-}"
docker_command=(docker)

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
  generate-abpos-validators.sh --release VERSION --amount AMOUNT [OPTIONS] [chain] <network> <withdrawal-address>
  generate-abpos-validators.sh --deposit-settings FILE --amount AMOUNT [OPTIONS] [chain] <network> <withdrawal-address>

Arguments:
  chain
      Chain whose Genesis Validator keys are being generated.
      Default: abcore

  network
      Network whose Genesis Validator keys are being generated.
      Supported values: testnet, mainnet.

  withdrawal-address
      Ethereum execution-layer address that receives validator withdrawals.
      The value must be a 20-byte hexadecimal address prefixed with 0x.

Options:
  --release VERSION
      Genesis Participation Release tag. The tag must end in -rc.0.

  --release-repo OWNER/REPO
      Release repository. Default: abdaodev/ab-pos-deploy.

  --release-url URL
      Download a specific Genesis Participation .tar.gz archive.

  --deposit-settings FILE
      Use a local public settings file instead of a Release.

  --amount AMOUNT
      Positive whole-token Deposit amount for each generated validator. This
      is selected by the Validator Operator and must satisfy the published
      Deposit settings.

  --validator-count COUNT
      Number of validators to generate. Default: 1000.

  --docker
      Generate keys with the Deposit CLI container. This is the default.

  --binary
      Download and run the official EthStaker Deposit CLI binary.

  -h, --help
      Show this help message and exit.

Environment variables:
  Command-line options take precedence over their equivalent environment
  variables.

  ABPOS_CHAIN_NAME
      Chain name used when it is omitted from the command.
      Default: abcore

  WITHDRAWAL_ADDRESS
      Withdrawal address used when the positional argument is omitted.

  VALIDATOR_COUNT
      Number of validators to generate.
      Default: 1000

  VALIDATOR_DEPOSIT_AMOUNT
      Alternative to --amount.

  ABPOS_ROOT_PATH
      Network output directory.
      Default: /data/<chain>/<network>

  DEPOSIT_SETTINGS_FILE
      Alternative to --deposit-settings.

  ABPOS_RELEASE_REPO
      Default repository used by --release.

  DEPOSIT_CLI_IMAGE
      Deposit CLI Docker image used by --docker.
      Default: ghcr.io/ethstaker/ethstaker-deposit-cli:latest

  DEPOSIT_CLI_RELEASE_VERSION
      EthStaker Deposit CLI Release tag used by --binary.
      Default: latest

Outputs:
  <ABPOS_ROOT_PATH>/keys/validator_keys/keystore-*.json
  <ABPOS_ROOT_PATH>/keys/validator_keys/deposit_data-*.json
  <ABPOS_ROOT_PATH>/keys/mnemonic.txt
  <ABPOS_ROOT_PATH>/keys/pwd.txt

Examples:
  ./generate-abpos-validators.sh \
    --release v1.0.0-rc.0 \
    --validator-count 1000 \
    --amount 2048000 \
    testnet \
    0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332

  ./generate-abpos-validators.sh --binary \
    --release v1.0.0-rc.0 \
    --validator-count 1000 \
    --amount 2048000 \
    testnet \
    0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332

  VALIDATOR_COUNT=10 \
    ABPOS_ROOT_PATH=/data/abcore/testnet-operator-a \
    ./generate-abpos-validators.sh \
    --deposit-settings ./deposit-settings.json \
    --amount 32000 \
    testnet \
    0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332

  WITHDRAWAL_ADDRESS=0x7EdC0CaDD6c20811058D4FB3EDA6F9218cCC7332 \
    ./generate-abpos-validators.sh \
    --deposit-settings ./deposit-settings.json \
    --amount 32000 \
    testnet

Security:
  Share only deposit_data-*.json with the Network Operator.
  Never share mnemonic.txt, pwd.txt, or validator keystores.
USAGE
}

function require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        fail "Required command not found: $1"
}

function install_missing_dependencies() {
    local specification command_name package_name
    local -a specifications=(
        "find:findutils"
        "jq:jq"
        "mv:coreutils"
        "openssl:openssl"
        "rmdir:coreutils"
    )
    local -a packages=()
    local -a privileged=()
    local -A selected_packages=()

    if [[ -z "${deposit_settings_file}" ]]; then
        specifications+=("curl:curl" "sha256sum:coreutils" "tar:tar")
    fi
    if [[ "${deployment_mode}" == "docker" ]]; then
        specifications+=("docker:docker.io")
    else
        specifications+=(
            "curl:curl"
            "install:coreutils"
            "sha256sum:coreutils"
            "tar:tar"
        )
    fi

    for specification in "${specifications[@]}"; do
        command_name="${specification%%:*}"
        package_name="${specification#*:}"
        command -v "${command_name}" >/dev/null 2>&1 && continue
        [[ -n "${selected_packages[${package_name}]:-}" ]] && continue
        selected_packages["${package_name}"]=1
        packages+=("${package_name}")
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] \
        || packages+=(ca-certificates)
    (( ${#packages[@]} > 0 )) || return 0

    [[ "$(uname -s)" == "Linux" ]] \
        || fail "Automatic dependency installation supports Linux only."
    command -v apt-get >/dev/null 2>&1 \
        || fail "Missing dependencies: ${packages[*]}. Automatic installation requires apt-get."
    if (( EUID != 0 )); then
        command -v sudo >/dev/null 2>&1 \
            || fail "Missing dependencies: ${packages[*]}. Install them as root."
        privileged=(sudo)
    fi

    color "34" "Installing required packages: ${packages[*]}"
    "${privileged[@]}" apt-get update
    "${privileged[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${packages[@]}"
}

function ensure_docker_available() {
    local -a privileged=()

    docker info >/dev/null 2>&1 && return 0
    if (( EUID != 0 )); then
        command -v sudo >/dev/null 2>&1 \
            || fail "Docker is installed but the current user cannot access it."
        privileged=(sudo)
    fi
    if command -v systemctl >/dev/null 2>&1; then
        "${privileged[@]}" systemctl enable --now docker >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        "${privileged[@]}" service docker start >/dev/null 2>&1 || true
    fi
    if docker info >/dev/null 2>&1; then
        return 0
    fi
    if (( EUID != 0 )) && sudo docker info >/dev/null 2>&1; then
        docker_command=(sudo docker)
        return 0
    fi
    fail "Docker is unavailable or permission was denied."
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

function cleanup_settings_download() {
    if [[ -n "${settings_download_dir}" && -d "${settings_download_dir}" ]]; then
        rm -rf -- "${settings_download_dir}"
    fi
}

function download_deposit_settings() {
    local release_json=""
    local archive_name
    local archive_url
    local checksum_url
    local archive_path
    local checksum_path
    local expected_sha256
    local actual_sha256
    local archive_listing
    local member
    local normalized_member
    local member_count=0

    if [[ -n "${settings_release}" ]]; then
        [[ "${settings_release}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.0$ ]] \
            || fail "Genesis Participation Release must use vMAJOR.MINOR.PATCH-rc.0."
        [[ "${settings_release_repo}" =~ ^[^/]+/[^/]+$ ]] \
            || fail "Release repository must use OWNER/REPO format."
        release_json="$(github_release_json "${settings_release_repo}" "${settings_release}")" \
            || fail "Unable to query Genesis Participation Release ${settings_release}."
        [[ "$(jq -r '.prerelease // false' <<<"${release_json}")" == "true" ]] \
            || fail "Genesis Participation Release ${settings_release} must be a Pre-release."
        archive_name="${chain_name}-${network}-${settings_release}.tar.gz"
        archive_url="$(jq -r --arg name "${archive_name}" \
            '[.assets[] | select(.name == $name)][0].browser_download_url // empty' \
            <<<"${release_json}")"
        checksum_url="$(jq -r --arg name "${archive_name}.sha256" \
            '[.assets[] | select(.name == $name)][0].browser_download_url // empty' \
            <<<"${release_json}")"
        [[ -n "${archive_url}" && -n "${checksum_url}" ]] \
            || fail "Release ${settings_release} does not contain ${archive_name} and its checksum."
    else
        archive_url="${settings_release_url}"
        archive_name="$(basename "${archive_url%%\?*}")"
        [[ "${archive_name}" =~ ^${chain_name}-${network}-v[0-9]+\.[0-9]+\.[0-9]+-rc\.0\.tar\.gz$ ]] \
            || fail "Genesis Participation archive must be named ${chain_name}-${network}-vMAJOR.MINOR.PATCH-rc.0.tar.gz."
        checksum_url="${archive_url}.sha256"
    fi

    settings_download_dir="$(mktemp -d /tmp/abpos-deposit-settings.XXXXXX)"
    trap cleanup_settings_download EXIT
    archive_path="${settings_download_dir}/${archive_name}"
    checksum_path="${archive_path}.sha256"
    color "34" "Downloading Genesis Participation Release: ${archive_url}"
    curl -fL "${archive_url}" -o "${archive_path}" \
        || fail "Unable to download ${archive_name}."
    curl -fsSL "${checksum_url}" -o "${checksum_path}" \
        || fail "Unable to download ${archive_name}.sha256."
    expected_sha256="$(awk 'NR == 1 { print $1 }' "${checksum_path}")"
    [[ "${expected_sha256}" =~ ^[0-9a-fA-F]{64}$ ]] \
        || fail "Invalid checksum for ${archive_name}."
    actual_sha256="$(sha256sum "${archive_path}" | awk '{ print $1 }')"
    [[ "${actual_sha256,,}" == "${expected_sha256,,}" ]] \
        || fail "Checksum verification failed for ${archive_name}."

    archive_listing="${settings_download_dir}/archive-contents.txt"
    tar -tzf "${archive_path}" >"${archive_listing}" \
        || fail "Unable to inspect ${archive_name}."
    while IFS= read -r member; do
        normalized_member="${member#./}"
        [[ -n "${normalized_member}" ]] || continue
        [[ "${normalized_member}" == "deposit-settings.json" ]] \
            || fail "Unexpected file in Genesis Participation archive: ${member}"
        member_count=$((member_count + 1))
    done <"${archive_listing}"
    [[ "${member_count}" -eq 1 ]] \
        || fail "Genesis Participation archive must contain only deposit-settings.json."
    tar -xzf "${archive_path}" -C "${settings_download_dir}" \
        --no-same-owner --no-same-permissions \
        || fail "Unable to extract ${archive_name}."
    deposit_settings_file="${settings_download_dir}/deposit-settings.json"
    [[ -f "${deposit_settings_file}" && ! -L "${deposit_settings_file}" ]] \
        || fail "Genesis Participation settings must be a regular file."
}

arguments=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --docker)
            [[ "${deployment_mode_selected}" == false || "${deployment_mode}" == "docker" ]] \
                || fail "--docker and --binary are mutually exclusive."
            deployment_mode="docker"
            deployment_mode_selected=true
            ;;
        --binary)
            [[ "${deployment_mode_selected}" == false || "${deployment_mode}" == "binary" ]] \
                || fail "--docker and --binary are mutually exclusive."
            deployment_mode="binary"
            deployment_mode_selected=true
            ;;
        --deposit-settings)
            [[ "$#" -ge 2 ]] || fail "--deposit-settings requires a file."
            deposit_settings_file="$2"
            shift
            ;;
        --release)
            [[ "$#" -ge 2 ]] || fail "--release requires a version."
            settings_release="$2"
            shift
            ;;
        --release-repo)
            [[ "$#" -ge 2 ]] || fail "--release-repo requires OWNER/REPO."
            settings_release_repo="$2"
            shift
            ;;
        --release-url)
            [[ "$#" -ge 2 ]] || fail "--release-url requires a URL."
            settings_release_url="$2"
            shift
            ;;
        --amount)
            [[ "$#" -ge 2 ]] || fail "--amount requires a value."
            deposit_amount="$2"
            shift
            ;;
        --validator-count)
            [[ "$#" -ge 2 ]] || fail "--validator-count requires a value."
            validator_count="$2"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            fail "Unknown option: $1"
            ;;
        *) arguments+=("$1") ;;
    esac
    shift
done

if [[ "${#arguments[@]}" -lt 1 || "${#arguments[@]}" -gt 3 ]]; then
    usage >&2
    fail "Expected an optional chain, a network, and an optional withdrawal address."
fi

chain_name="${ABPOS_CHAIN_NAME:-abcore}"
first_argument="${arguments[0],,}"
case "${first_argument}" in
    test | testnet | main | mainnet)
        network="${first_argument}"
        withdrawal_address="${arguments[1]:-${WITHDRAWAL_ADDRESS:-}}"
        [[ "${#arguments[@]}" -le 2 ]] \
            || fail "Too many positional arguments for the default chain."
        ;;
    *)
        [[ "${#arguments[@]}" -ge 2 ]] || fail "Network is required after chain: ${first_argument}"
        chain_name="${first_argument}"
        network="${arguments[1],,}"
        withdrawal_address="${arguments[2]:-${WITHDRAWAL_ADDRESS:-}}"
        ;;
esac

case "${network}" in
    test | testnet) network="testnet" ;;
    main | mainnet) network="mainnet" ;;
    *) fail "Unsupported network: ${network}" ;;
esac

[[ "${chain_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "Invalid chain name: ${chain_name}"

if [[ -z "${withdrawal_address}" ]]; then
    usage
    fail "Withdrawal address is required."
fi

if [[ ! "${withdrawal_address}" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    fail "Invalid withdrawal address: ${withdrawal_address}"
fi

if [[ ! "${validator_count}" =~ ^[1-9][0-9]*$ ]]; then
    fail "--validator-count must be a positive integer."
fi

readonly validator_count chain_name network
settings_source_count=0
[[ -z "${deposit_settings_file}" ]] || settings_source_count=$((settings_source_count + 1))
[[ -z "${settings_release}" ]] || settings_source_count=$((settings_source_count + 1))
[[ -z "${settings_release_url}" ]] || settings_source_count=$((settings_source_count + 1))
[[ "${settings_source_count}" -eq 1 ]] \
    || fail "Specify exactly one of --release, --release-url, or --deposit-settings."
[[ -n "${deposit_amount}" ]] \
    || fail "--amount is required. Choose the per-validator Deposit amount."
install_missing_dependencies
require_command jq
if [[ -z "${deposit_settings_file}" ]]; then
    require_command curl
    require_command sha256sum
    require_command tar
    download_deposit_settings
fi
[[ -s "${deposit_settings_file}" ]] \
    || fail "Deposit settings file is missing or empty: ${deposit_settings_file}"
require_command jq
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
    ' "${deposit_settings_file}" >/dev/null \
    || fail "Invalid deposit settings for ${chain_name}/${network}: ${deposit_settings_file}"
readonly deposit_settings_file
readonly deposit_amount
readonly chain_setting="$(jq -c '.' "${deposit_settings_file}")"
readonly amount_multiplier="$(jq -r '.multiplier' <<<"${chain_setting}")"
readonly amount_divisor="$(jq -r '.divisor' <<<"${chain_setting}")"
parse_whole_token_amount_to_gwei "--amount" "${deposit_amount}"
readonly public_amount_gwei="${parsed_gwei}"
(( public_amount_gwei % amount_divisor == 0 )) \
    || fail "--amount cannot be represented exactly with the published Deposit conversion."
readonly cli_amount_gwei=$((public_amount_gwei / amount_divisor))
(( cli_amount_gwei <= max_exact_integer / amount_multiplier )) \
    || fail "--amount is too large after applying the published Deposit conversion."
readonly expected_deposit_gwei=$((cli_amount_gwei * amount_multiplier))
parse_whole_token_amount_to_gwei \
    "Published minimum activation amount" \
    "$(jq -r '.min_activation_amount' <<<"${chain_setting}")"
readonly public_minimum_activation_gwei="${parsed_gwei}"
(( public_minimum_activation_gwei % amount_divisor == 0 )) \
    || fail "Published minimum activation amount cannot be represented exactly."
readonly cli_minimum_activation_gwei=$((public_minimum_activation_gwei / amount_divisor))
(( cli_minimum_activation_gwei <= max_exact_integer / amount_multiplier )) \
    || fail "Published minimum activation amount is too large."
readonly minimum_activation_gwei=$((cli_minimum_activation_gwei * amount_multiplier))
(( expected_deposit_gwei >= minimum_activation_gwei )) \
    || fail "--amount must be at least $(jq -r '.min_activation_amount' <<<"${chain_setting}")."
parse_whole_token_amount_to_gwei \
    "Published minimum Deposit amount" \
    "$(jq -r '.min_deposit_amount' <<<"${chain_setting}")"
readonly public_minimum_deposit_gwei="${parsed_gwei}"
(( public_minimum_deposit_gwei % amount_divisor == 0 )) \
    || fail "Published minimum Deposit amount cannot be represented exactly."
readonly cli_minimum_deposit_gwei=$((public_minimum_deposit_gwei / amount_divisor))
format_gwei_amount "${cli_amount_gwei}"
readonly cli_deposit_amount="${formatted_amount}"
format_gwei_amount "${cli_minimum_activation_gwei}"
readonly cli_minimum_activation_amount="${formatted_amount}"
format_gwei_amount "${cli_minimum_deposit_gwei}"
readonly cli_minimum_deposit_amount="${formatted_amount}"
readonly deposit_cli_chain_setting="$(jq -c \
    --argjson min_activation_amount "${cli_minimum_activation_amount}" \
    --argjson min_deposit_amount "${cli_minimum_deposit_amount}" '
        del(.divisor)
        | .min_activation_amount = $min_activation_amount
        | .min_deposit_amount = $min_deposit_amount
    ' <<<"${chain_setting}")"
readonly root_path="${ABPOS_ROOT_PATH:-/data/${chain_name}/${network}}"
readonly keys_path="${root_path}/keys"
readonly validator_keys_path="${keys_path}/validator_keys"
readonly legacy_validator_keys_path="${validator_keys_path}/validator_keys"
readonly password_path="${keys_path}/pwd.txt"
readonly mnemonic_path="${keys_path}/mnemonic.txt"
readonly bin_path="${root_path}/bin"

require_command find
require_command jq
require_command mv
require_command openssl
require_command rmdir
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    require_command chown
fi

if [[ "${deployment_mode}" == "docker" ]]; then
    require_command docker
    ensure_docker_available
else
    require_command curl
    require_command install
    require_command jq
    require_command sha256sum
    require_command tar
    case "$(uname -m)" in
        x86_64 | amd64) platform_arch="amd64" ;;
        aarch64 | arm64) platform_arch="arm64" ;;
        *) fail "Unsupported host architecture: $(uname -m)" ;;
    esac
fi

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

    mkdir -p "${bin_path}"
    temporary_dir="$(mktemp -d "${root_path}/deposit-cli-download.XXXXXX")"
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
    install -m 0755 "${extracted_binary}" "${bin_path}/deposit.new"
    mv -f -- "${bin_path}/deposit.new" "${bin_path}/deposit"
    rm -rf -- "${temporary_dir}"
    color "32" "Installed EthStaker Deposit CLI ${release_tag}: ${bin_path}/deposit"
}

umask 077

if ! mkdir -p "${validator_keys_path}"; then
    fail "Cannot create ${validator_keys_path}. Check the directory permissions."
fi

if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown "${host_uid}:${host_gid}" "${keys_path}" "${validator_keys_path}"
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

    if [[ "${deployment_mode}" == "binary" ]]; then
        install_deposit_cli_binary
    fi

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
        if [[ "${deployment_mode}" == "binary" ]]; then
            "${bin_path}/deposit" \
                --non_interactive \
                --ignore_connectivity \
                --language english \
                generate-mnemonic \
                --mnemonic_language=english \
                "--output_file=${mnemonic_path}"
        else
            "${docker_command[@]}" run --rm \
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
        fi

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

    if [[ "${deployment_mode}" == "binary" ]]; then
        generation_dir="$(mktemp -d "${keys_path}/deposit-output.XXXXXX")"
        generated_keys_dir="${generation_dir}/validator_keys"
        if ! "${bin_path}/deposit" \
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
            --amount="${cli_deposit_amount}" \
            --devnet_chain_setting="${deposit_cli_chain_setting}" \
            "--folder=${generation_dir}"; then
            rm -rf -- "${generation_dir}"
            fail "EthStaker Deposit CLI failed to generate validator keys."
        fi
        [[ -d "${generated_keys_dir}" ]] || {
            rm -rf -- "${generation_dir}"
            fail "EthStaker Deposit CLI did not create validator_keys/."
        }
        cp -a "${generated_keys_dir}/." "${validator_keys_path}/"
        rm -rf -- "${generation_dir}"
    else
        "${docker_command[@]}" run --rm \
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
            --amount="${cli_deposit_amount}" \
            --devnet_chain_setting="${deposit_cli_chain_setting}" \
            --folder=/app
        normalize_legacy_output
    fi

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

jq -e \
    --arg chain "${chain_name}" \
    --arg fork_version "$(jq -r '.genesis_fork_version' <<<"${chain_setting}")" \
    --argjson expected_amount "${expected_deposit_gwei}" '
        type == "array"
        and length > 0
        and all(.[];
            .network_name == $chain
            and (("0x" + (.fork_version | sub("^0x"; ""))) | ascii_downcase)
                == ($fork_version | ascii_downcase)
            and .amount == $expected_amount
        )
    ' "${deposit_file}" >/dev/null \
    || fail "Generated deposit data does not match ${deposit_settings_file}."

chmod 644 "${deposit_file}"
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown -R "${host_uid}:${host_gid}" "${keys_path}"
fi

color "32" "Validator generation completed successfully."
color "1;36" "Chain: ${chain_name}"
color "1;36" "Network: ${network}"
color "1;36" "Withdrawal address: ${withdrawal_address}"
color "1;36" "Validator count: ${validator_count}"
color "1;36" "Deposit amount per validator: ${deposit_amount}"
color "1;36" "Validator keys: ${validator_keys_path}"
color "1;36" "Mnemonic backup: ${mnemonic_path}"
color "1;36" "Keystore password: ${password_path}"
color "32" "Genesis deposit data: ${deposit_file}"
color "33" \
    "Share only the deposit data JSON with operations staff."
