#!/usr/bin/env bash
set -Eeuo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT
geth_data_dir="${temporary_dir}/geth"
share_dir="${temporary_dir}/share"
mkdir -p "${geth_data_dir}" "${share_dir}"
for function_name in chain_config_files_match initialized_genesis_matches_release record_initialized_genesis; do
    source <(sed -n "/^function ${function_name}()/,/^}/p" "${root_dir}/ab-pos.sh")
done

expect_init() {
    if initialized_genesis_matches_release; then
        printf 'FAIL: init must not be skipped: %s\n' "$1" >&2
        exit 1
    fi
}

jq -n '{config: {chainId: 2688}, timestamp: "0x1", alloc: {}}' > "${share_dir}/genesis.json"
expect_init 'no successful-init record'
record_initialized_genesis
initialized_genesis_matches_release
cp "${share_dir}/genesis.json" "${temporary_dir}/original.json"
for change in '.timestamp = "0x2"' '.alloc = {"0000000000000000000000000000000000000001": {balance: "0x1"}}' '.extraData = "0x01"' '.config.shanghaiTime = 100'; do
    jq "${change}" "${temporary_dir}/original.json" > "${share_dir}/genesis.json"
    expect_init "${change}"
done
printf 'invalid\n' > "${geth_data_dir}/.initialized-genesis.sha256"
expect_init 'invalid successful-init record'
record_initialized_genesis
initialized_genesis_matches_release
printf 'Genesis init checks passed.\n'

# Optional, lightweight integration check against a locally built Geth. No
# network access, mining, Docker, or existing node data is used.
if [[ -n "${GETH_BIN:-}" ]]; then
    jq -n '{config: {chainId: 2688, homesteadBlock: 0, eip150Block: 0,
      eip155Block: 0, eip158Block: 0, byzantiumBlock: 0, constantinopleBlock: 0,
      petersburgBlock: 0, istanbulBlock: 0, berlinBlock: 0, londonBlock: 0,
      terminalTotalDifficulty: 0}, gasLimit: "0x1c9c380", difficulty: "0x0",
      timestamp: "0x1", alloc: {}}' > "${temporary_dir}/base.json"
    "${GETH_BIN}" --datadir="${temporary_dir}/integration" init "${temporary_dir}/base.json" > "${temporary_dir}/init.log" 2>&1
    jq '.config.shanghaiTime = 2000000000' "${temporary_dir}/base.json" > "${temporary_dir}/fork.json"
    "${GETH_BIN}" --datadir="${temporary_dir}/integration" init "${temporary_dir}/fork.json" >> "${temporary_dir}/init.log" 2>&1
    jq '.timestamp = "0x2"' "${temporary_dir}/fork.json" > "${temporary_dir}/different.json"
    if "${GETH_BIN}" --datadir="${temporary_dir}/integration" init "${temporary_dir}/different.json" > "${temporary_dir}/mismatch.log" 2>&1; then
        printf 'FAIL: incompatible genesis was accepted.\n' >&2
        exit 1
    fi
    grep -q 'incompatible genesis' "${temporary_dir}/mismatch.log"
    printf 'Geth accepted the fork update and rejected a changed genesis block.\n'
fi
