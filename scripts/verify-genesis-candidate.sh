#!/usr/bin/env bash
set -Eeuo pipefail

function fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ "$#" -eq 2 ]] \
    || fail "usage: $0 CANDIDATE_NETWORK_ARCHIVE FINAL_NETWORK_ARCHIVE"

readonly candidate_archive="$1"
readonly final_archive="$2"
readonly temporary_dir="$(mktemp -d)"
readonly candidate_dir="${temporary_dir}/candidate"
readonly final_dir="${temporary_dir}/final"

trap 'rm -rf -- "${temporary_dir}"' EXIT

[[ -s "${candidate_archive}" ]] || fail "candidate archive not found: ${candidate_archive}"
[[ -s "${final_archive}" ]] || fail "final archive not found: ${final_archive}"

mkdir -p "${candidate_dir}" "${final_dir}"
tar -xzf "${candidate_archive}" -C "${candidate_dir}" --no-same-owner --no-same-permissions
tar -xzf "${final_archive}" -C "${final_dir}" --no-same-owner --no-same-permissions

immutable_files=(
    genesis.json
    genesis.ssz
    config.yaml
    config.prysm.yaml
    deposit_contract_block.txt
)
optional_immutable_files=(
    deposit_contract.txt
    deposit_contract_block_hash.txt
    genesis_validators_root.txt
    deploy_block.txt
)

for name in "${immutable_files[@]}"; do
    [[ -f "${candidate_dir}/${name}" ]] || fail "candidate archive is missing ${name}"
    [[ -f "${final_dir}/${name}" ]] || fail "final archive is missing ${name}"
    cmp -s -- "${candidate_dir}/${name}" "${final_dir}/${name}" \
        || fail "${name} changed between the Genesis Candidate and Final Release"
done

for name in "${optional_immutable_files[@]}"; do
    if [[ -e "${candidate_dir}/${name}" || -e "${final_dir}/${name}" ]]; then
        [[ -f "${candidate_dir}/${name}" && -f "${final_dir}/${name}" ]] \
            || fail "${name} must have the same presence in the Genesis Candidate and Final Release"
        cmp -s -- "${candidate_dir}/${name}" "${final_dir}/${name}" \
            || fail "${name} changed between the Genesis Candidate and Final Release"
    fi
done

printf 'Verified that the Final Genesis files match the Candidate archive.\n'
