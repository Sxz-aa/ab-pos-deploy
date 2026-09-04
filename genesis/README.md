# AB PoS Genesis Participation and Release Guide

This guide covers the pre-genesis workflow for Genesis Validator Operators, Infrastructure Operators, and Network Operators. It is intentionally separate from the public [post-genesis node deployment guide](../README.md).

The central security boundary is simple: each Validator Operator keeps all signing material, while the Network Operator receives only public deposit data and publishes only public network material.

## 1. Scripts and lifecycle

| Script | Responsibility | Primary user | Lifecycle stage |
| --- | --- | --- | --- |
| `generate-abpos-validators.sh` | Generate genesis validator secrets, keystores, and deposit data | Genesis Validator Operator | Before genesis is built |
| `generate-abpos-genesis.sh` | Export Deposit settings, then build and verify execution and consensus genesis files | Network Operator | Before participation and after deposit collection |
| `ab-pos.sh` | Download a network Release and deploy Geth, a beacon node, and optionally a validator client | Node and infrastructure operators | After a Release is published |

On Debian and Ubuntu, each script installs missing runtime dependencies for
its installation or generation command.

Genesis Validator Operators and Infrastructure Operators use Docker by default,
or native binaries by passing `--binary` to `generate-abpos-validators.sh` or
`ab-pos.sh`. Network Operators build Genesis with Docker only through
`generate-abpos-genesis.sh`.

`generate-abpos-validators.sh` does not build genesis files or deploy a node. `ab-pos.sh --genesis --validator` does not generate keys; it imports the same keys that were included in the genesis validator set.

## 2. Who does what

| Participant | Responsibility |
| --- | --- |
| Genesis Validator Operator | Use the supplied Deposit settings to generate validator keys, back up the mnemonic, send `deposit_data-*.json`, then start the Candidate Release and return the displayed public enode and ENR. |
| Infrastructure Operator | Start a long-lived public RPC node from the Candidate Release and return the displayed public enode and ENR. |
| Network Operator | Build the Genesis Candidate, collect public node identities, publish the Final Genesis Release, and publish checkpoint URLs after finalization. |

The Network Operator never needs another operator's mnemonic, password, keystores, signing keys, or slashing protection data.

## 3. End-to-end genesis flow

```text
Network Operator
  -> review values.env and generate deposit-settings.json
  -> publish the settings-only vMAJOR.MINOR.PATCH-rc.0 Pre-release

Genesis Validator Operator
  -> run the version-pinned generator command from the Network Operator
  -> generate mnemonic, password, keystores, and deposit data from rc.0
  -> back up the mnemonic and keep all private material secret
  -> send only deposit_data-*.json

Network Operator
  -> validate and combine deposit records
  -> build genesis.json and genesis.ssz
  -> publish a Genesis Candidate Pre-release

Genesis Validator and Infrastructure Operators
  -> run ab-pos.sh --genesis with the Candidate; Validator nodes add --validator
  -> send the displayed execution enode and consensus ENR

Network Operator
  -> publish the Final Genesis Release with the collected bootnodes

Genesis Validator and Infrastructure Operators
  -> run ab-pos.sh again with the Final Genesis Release
  -> confirm synchronization, finality, and Validator duties where applicable

Network Operator
  -> verify the published checkpoint endpoint after finalization
  -> mark the tested Final Release as latest for ordinary nodes
```

## 4. Prepare Genesis participation settings (Network Operator)

Before any keys are generated, the Network Operator prepares the reviewed
Genesis workspace and exports the public Deposit settings:

```bash
cp -a genesis/config-template genesis/config
vi genesis/config/values.env
```

The settings are derived from the reviewed `values.env`:

| Setting | Source |
| --- | --- |
| Deposit CLI network name | `CHAIN_NAME` |
| Deposit fork version | `GENESIS_FORK_VERSION` |
| Exit fork version | `CAPELLA_FORK_VERSION` |
| Deposit amount conversion | `DEPOSIT_AMOUNT_MULTIPLIER` and `DEPOSIT_AMOUNT_DIVISOR` |
| Minimum Deposit | `MIN_DEPOSIT_AMOUNT` |
| Minimum activation amount | `MIN_ACTIVATION_AMOUNT` |

The consensus Deposit amount equals the native-token amount multiplied by
`DEPOSIT_AMOUNT_MULTIPLIER` and divided by `DEPOSIT_AMOUNT_DIVISOR`. These
values are published as `multiplier` and `divisor`; Validator Operators do not
configure them locally. Genesis premine calculation applies the same ratio in
the opposite direction.

`MIN_DEPOSIT_AMOUNT`, `MIN_ACTIVATION_AMOUNT`, `MAX_DEPOSIT_AMOUNT`,
`VALIDATOR_BALANCE`, and `TARGET_TOTAL_SUPPLY` are whole native-token amounts.
Gwei is used only internally and in Deposit Data.

```bash
./genesis/generate-abpos-genesis.sh --prepare-deposit-settings --export
```

The command writes `genesis/config/deposit-settings.json` and displays its path
and contents, then exports it to `<chain>/<network>/share`. The initial file
contains a zero `genesis_validator_root` because the Genesis state does not
exist yet; that field does not participate in Deposit Data signing.

Publish the settings-only `rc.0` Pre-release:

```bash
source genesis/config/values.env
share_dir="${CHAIN_NAME}/${NETWORK_NAME}/share"
participation_tag="v1.0.0-rc.0"
git add "${share_dir}/deposit-settings.json"
git commit -S -m "config: prepare ${CHAIN_NAME}/${NETWORK_NAME} Genesis participation"
git tag -s "${participation_tag}" \
  -m "AB PoS ${CHAIN_NAME}/${NETWORK_NAME} Genesis Participation ${participation_tag}"
git push origin main "${participation_tag}"
```

GitHub publishes `${CHAIN_NAME}-${NETWORK_NAME}-${participation_tag}.tar.gz`
with only `deposit-settings.json` and its checksum. It does not build or
publish AB Geth for `rc.0`.

## 5. Generate Genesis validator material (Genesis Validator Operator)

### 5.1 Prerequisites

- A confirmed 20-byte execution-layer withdrawal address
- A secure offline location for backing up the mnemonic

### 5.2 Download and run the generator

```bash
participation_tag="v1.0.0-rc.0"
curl -fsSL \
  "https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/${participation_tag}/genesis/generate-abpos-validators.sh" |
sudo bash -s -- \
  --release "${participation_tag}" \
  --validator-count 1000 \
  --amount 2048000 \
  testnet \
  0x0000000000000000000000000000000000000000
```

Replace the example withdrawal address before running the command.

The example generates:

- 1000 validators
- 2,048,000 AB per validator, equal to 2,048 consensus-layer staking units
  with the published divisor of 1000
- the public chain parameters from `deposit-settings.json`
- `0x02` compounding withdrawal credentials
- `/data/abcore/<network>` as the output root

### 5.3 Generated files

```text
/data/abcore/testnet/keys/
|-- mnemonic.txt
|-- pwd.txt
`-- validator_keys/
    |-- keystore-*.json
    `-- deposit_data-*.json
```

| File | Purpose | May be shared? |
| --- | --- | --- |
| `mnemonic.txt` | Restores the complete validator key set | Never |
| `pwd.txt` | Decrypts validator keystores | Never |
| `keystore-*.json` | Contains validator signing keys | Never |
| `deposit_data-*.json` | Public records used to build genesis | Network Operator only |

One deposit data file normally contains an array with many validator records. There is no requirement to create one deposit file per validator.

### 5.4 Submit Deposit Data

Back up `mnemonic.txt` before the handoff. Keep `pwd.txt` and all keystores
private. Then provide only the deposit data file to the Network Operator
through the approved secure channel.

Useful local checks:

```bash
jq 'length' /data/abcore/testnet/keys/validator_keys/deposit_data-*.json
sha256sum /data/abcore/testnet/keys/validator_keys/deposit_data-*.json
```

## 6. Build the Genesis Candidate (Network Operator)

### 6.1 Record and validate accepted Deposit Data

The Network Operator should record the submitting operator, expected validator
count, file checksum, withdrawal address, and accepted network parameters
without taking custody of any private key material. The Genesis builder
validates every submitted amount against `MIN_ACTIVATION_AMOUNT` and
`MAX_DEPOSIT_AMOUNT` and calculates total stake from the accepted Deposit Data;
different operators do not need to select the same amount.

The Network Operator must continue with the same reviewed configuration that
produced the `rc.0` settings. Changing any Deposit parameter now makes the
builder stop.

Set `GENESIS_DELAY` with enough time to collect all node identities and publish the Final Release before the Beacon Genesis time.

Copy every accepted deposit data file into `validator-deposits`. Subdirectories are also supported; the builder recursively reads every `deposit_data-*.json` file below this directory.

```bash
cp /secure/deposits/deposit_data-*.json \
  genesis/config/validator-deposits/
```

### 6.2 Generate and export Genesis

```bash
./genesis/generate-abpos-genesis.sh
```

The builder validates the deposit records and writes the public files to
`genesis/config/genesis-output`. Its final `deposit-settings.json` contains the
actual `genesis_validator_root` and is included in the Network Release. Review
the generated files before continuing.

Export the reviewed output to the chain and network selected in `values.env`.
The command compares existing files before copying them and preserves node
lists already present in the target directory. Use `--force` only after
reviewing an expected difference.

```bash
./genesis/generate-abpos-genesis.sh --export
```

`CHAIN_NAME` identifies the chain and is checked against the network name recorded in deposit data. `NETWORK_NAME` selects its environment, such as `testnet` or `mainnet`. `CONFIG_NAME` is their unique combined consensus configuration name.

### 6.3 Publish the Candidate Release

Commit the Candidate files and push a signed Candidate tag. GitHub publishes it as a Pre-release:

```bash
candidate_tag="v1.0.0-rc.1"
git add "${share_dir}"
git commit -S -m "config: prepare ${CHAIN_NAME}/${NETWORK_NAME} Genesis Candidate"
git tag -s "${candidate_tag}" -m "AB PoS ${CHAIN_NAME}/${NETWORK_NAME} Genesis Candidate ${candidate_tag}"
git push origin main "${candidate_tag}"
```

## 7. Start Candidate nodes and submit node information (Genesis Validator and Infrastructure Operators)

Every Genesis Validator Operator starts the Candidate with the same keys used in the submitted deposit data:

```bash
candidate_tag="v1.0.0-rc.1"
curl -fsSLO \
  "https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/${candidate_tag}/ab-pos.sh"

sudo bash ab-pos.sh testnet prysm geth \
  --release "${candidate_tag}" \
  --genesis \
  --validator \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Replace the example fee recipient before the first Validator installation.

Every Infrastructure Operator contributing a long-lived RPC node runs:

```bash
sudo bash ab-pos.sh testnet prysm geth \
  --release "${candidate_tag}" \
  --genesis
```

Use `mainnet` instead of `testnet` when applicable, and `lighthouse` instead of `prysm` when selected. Each command displays:

```text
Genesis node information:
  Public IP: ...
  Execution enode: enode://...
  Consensus ENR: enr:...
```

Send the displayed enode and ENR to the Network Operator. Never send files from `keys/` or `config/`.

## 8. Publish the Final Release (Network Operator)

The Network Operator adds one consensus ENR per line to `bootstrap_nodes.txt`,
one execution enode per line to `bootstrap_nodes_execution.txt`, and the fixed
Checkpoint endpoint to `checkpoint_sync_urls.txt`. Then commit these files and
push the Final tag. GitHub Actions validates the files, builds the artifacts,
and publishes the Release. Do not run the Genesis builder again or change any
other generated network file.

```bash
vi "${share_dir}/bootstrap_nodes.txt"
vi "${share_dir}/bootstrap_nodes_execution.txt"
vi "${share_dir}/checkpoint_sync_urls.txt"

make verify-bootnodes CHAIN="${CHAIN_NAME}" NETWORK="${NETWORK_NAME}"

final_tag="v1.0.0"
git add \
  "${share_dir}/bootstrap_nodes.txt" \
  "${share_dir}/bootstrap_nodes_execution.txt" \
  "${share_dir}/checkpoint_sync_urls.txt"
git commit -S -m "config: finalize ${CHAIN_NAME}/${NETWORK_NAME} Genesis network"
git tag -s "${final_tag}" -m "AB PoS ${CHAIN_NAME}/${NETWORK_NAME} ${final_tag}"
git push origin main "${final_tag}"
```

Run the live verification while every submitted node is online. It validates each signed ENR, performs a Discovery v5 ping and resolution, and completes an RLPx handshake with each execution node. The first run builds the local `devp2p` verification tool with Docker.

When a matching Candidate Release exists, the Final Release workflow permits
only the two node lists and Checkpoint endpoints to change.

## 9. Restart nodes with the Final Release (Genesis Validator and Infrastructure Operators)

After the Final Release is available, every Candidate participant reruns the same node command with the Final tag.

Validator node:

```bash
sudo bash ab-pos.sh testnet prysm geth \
  --release v1.0.0 \
  --genesis \
  --validator
```

Infrastructure RPC node:

```bash
sudo bash ab-pos.sh testnet prysm geth \
  --release v1.0.0 \
  --genesis
```

The installer preserves the chain data, imported validator wallet, fee
recipient, JWT, and P2P identities.

## 10. Verify the Final network and mark the Release as latest (Network Operator)

After the network finalizes, verify execution and consensus synchronization,
peer connectivity, finality, Validator duties, and the Checkpoint endpoint.
Then test the Final Release without `--genesis` and mark it as the latest
GitHub Release.

## 11. Security rules

- Never commit or release mnemonics, passwords, keystores, node private keys, or slashing protection databases.
- Never run one validator pubkey in two validator clients at the same time.
- Verify the Release source, checksum, chain ID, fork versions, genesis validator root, deposit configuration, bootnodes, and checkpoint providers.
- Compare finalized roots from independent trusted sources before selecting a checkpoint.
- Back up slashing protection data before moving validators.
- Treat voluntary exit as irreversible for the exited validator index.
