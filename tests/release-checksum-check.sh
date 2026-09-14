#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -eq 0 ]]; then
    for scenario in local-valid local-missing local-invalid local-mismatch remote-valid remote-cached remote-missing remote-invalid remote-mismatch; do
        bash "$0" "${scenario}"
    done
    printf 'Release checksum checks passed (9 scenarios).\n'
    exit 0
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT
scenario="$1"
chain_name=abcore
network=testnet
genesis_mode=true
data_dir="${temporary_dir}/data"
share_dir="${data_dir}/share"
fixture_dir="${temporary_dir}/fixture"
archive_name=abcore-testnet-test.tar.gz
mkdir -p "${share_dir}" "${fixture_dir}" "${temporary_dir}/cache"
printf 'original\n' > "${share_dir}/sentinel"
for name in genesis.json genesis.ssz config.yaml config.prysm.yaml deposit_contract_block.txt genesis_validators_root.txt deposit-settings.json client-versions.json; do
    printf 'fixture\n' > "${fixture_dir}/${name}"
done
tar -czf "${temporary_dir}/${archive_name}" -C "${fixture_dir}" .
sha256sum "${temporary_dir}/${archive_name}" > "${temporary_dir}/${archive_name}.sha256"

function fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
function color() { printf '%s\n' "$2"; }
function yaml_scalar() { printf 'abcore-testnet\n'; }
# Mock only transport: actual sha256sum, tar extraction, and share replacement
# still run. Never access the network or installed node data.
function curl() {
    local url="$2" output="$4"
    printf '%s\n' "${url}" >> "${temporary_dir}/requests"
    if [[ "${url}" == *.sha256 ]]; then
        [[ "${scenario}" != remote-missing ]] || return 22
        cp "${temporary_dir}/${archive_name}.sha256" "${output}"
    else
        cp "${temporary_dir}/${archive_name}" "${output}"
    fi
}
source <(sed -n '/^function download_release()/,/^}/p' "${root_dir}/ab-pos.sh")
case "${scenario}" in
    *-missing) rm -- "${temporary_dir}/${archive_name}.sha256" ;;
    *-invalid) printf 'invalid\n' > "${temporary_dir}/${archive_name}.sha256" ;;
    *-mismatch) printf '%064d\n' 0 > "${temporary_dir}/${archive_name}.sha256" ;;
esac
if [[ "${scenario}" == local-* ]]; then
    network_release_url="file://${temporary_dir}/${archive_name}"
else
    network_release_url="https://example.invalid/${archive_name}"
    if [[ "${scenario}" == remote-cached || "${scenario}" == remote-missing ]]; then
        cp "${temporary_dir}/${archive_name}" "${temporary_dir}/cache/"
        # Even an old cached checksum must not bypass a failed remote fetch.
        sha256sum "${temporary_dir}/${archive_name}" > "${temporary_dir}/cache/${archive_name}.sha256"
    fi
fi
cd "${temporary_dir}/cache"
export -f download_release fail color yaml_scalar curl
export chain_name network genesis_mode data_dir share_dir network_release_url temporary_dir archive_name scenario
status=0
bash -c 'set -Eeuo pipefail; download_release' > "${temporary_dir}/result.log" 2>&1 || status=$?
case "${scenario}" in
    *-valid|remote-cached)
        [[ "${status}" -eq 0 && ! -e "${share_dir}/sentinel" && -s "${share_dir}/genesis.json" ]] \
            || { cat "${temporary_dir}/result.log"; exit 1; }
        ;;
    *)
        [[ "${status}" -ne 0 && "$(< "${share_dir}/sentinel")" == original ]] \
            || { cat "${temporary_dir}/result.log"; exit 1; }
        grep -qi 'checksum' "${temporary_dir}/result.log"
        ;;
esac
if [[ "${scenario}" == remote-cached || "${scenario}" == remote-missing || "${scenario}" == remote-invalid ]]; then
    [[ "$(wc -l < "${temporary_dir}/requests")" -eq 1 ]] \
        || fail "Archive was downloaded unexpectedly: ${scenario}"
fi
printf 'PASS: %s\n' "${scenario}"
