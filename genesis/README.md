# AB PoS Genesis Participation and Release Guide

This guide covers the pre-genesis workflow for Genesis Validator Operators, Infrastructure Operators, and Network Operators. It is intentionally separate from the public [post-genesis node deployment guide](../README.md).

The central security boundary is simple: each Validator Operator keeps all signing material, while the Network Operator receives only public deposit data and publishes only public network material.

## 1. Scripts and lifecycle

| Script | Responsibility | Primary user | Lifecycle stage |
| --- | --- | --- | --- |
| `generate-abpos-validators.sh` | Generate genesis validator secrets, keystores, and deposit data | Genesis Validator Operator | Before genesis is built |
| `generate-abpos-genesis.sh` | Build and verify execution and consensus genesis files from accepted deposit data | Network Operator | After deposit data is collected |
| `ab-pos.sh` | Download a network Release and deploy Geth, a beacon node, and optionally a validator client | Node and infrastructure operators | After a Release is published |

`generate-abpos-validators.sh` does not build genesis files or deploy a node. `ab-pos.sh --genesis --validator` does not generate keys; it imports the same keys that were included in the genesis validator set.

## 2. Who does what

| Participant | Responsibility |
| --- | --- |
| Genesis Validator Operator | Generate and back up validator keys, send `deposit_data-*.json`, then start the Candidate Release and return the displayed public enode and ENR. |
| Infrastructure Operator | Start a long-lived public RPC node from the Candidate Release and return the displayed public enode and ENR. |
| Network Operator | Build the Genesis Candidate, collect public node identities, publish the Final Genesis Release, and publish checkpoint URLs after finalization. |

The Network Operator never needs another operator's mnemonic, password, keystores, signing keys, or slashing protection data.

## 3. End-to-end genesis flow

```text
Genesis Validator Operator
  -> generate mnemonic, password, keystores, and deposit data
  -> back up all private material
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

## 4. Generate genesis validator material

### 4.1 Prerequisites

- Docker Engine when using the default Docker mode
- `jq` when using `--binary`
- A confirmed 20-byte execution-layer withdrawal address
- A secure backup location that is not inside this repository

Prepare the default output directory so that generated files belong to the current user:

```bash
sudo mkdir -p /data/abpos
sudo chown "$(id -u):$(id -g)" /data/abpos
```

### 4.2 Download and run the generator

```bash
mkdir -p ab-pos-genesis && cd ab-pos-genesis

curl -fLO \
  https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/genesis/generate-abpos-validators.sh

chmod +x generate-abpos-validators.sh

./generate-abpos-validators.sh \
  testnet \
  0x0000000000000000000000000000000000000000
```

Replace the example withdrawal address before running the command.

To use the official EthStaker Deposit CLI binary instead of Docker:

```bash
./generate-abpos-validators.sh --binary \
  testnet \
  0x0000000000000000000000000000000000000000
```

The binary archive and its checksum are downloaded from the selected EthStaker Deposit CLI GitHub Release. The verified executable is installed under `<ABPOS_ROOT_PATH>/bin/`.

The current generator defaults to:

- 1000 validators
- 2048 ETH per validator deposit record
- `0x02` compounding withdrawal credentials
- AB Core devnet chain settings
- `/data/abpos/<network>` as the output root

### 4.3 Generated files

```text
/data/abpos/testnet/keys/
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

### 4.4 Configuration

```bash
VALIDATOR_COUNT=10 \
ABPOS_ROOT_PATH=/data/abpos/testnet-operator-a \
./generate-abpos-validators.sh \
  testnet \
  0x0000000000000000000000000000000000000000
```

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `WITHDRAWAL_ADDRESS` | None | Used when the positional address is omitted |
| `VALIDATOR_COUNT` | `1000` | Number of validators to generate |
| `ABPOS_ROOT_PATH` | `/data/abpos/<network>` | Network output directory |
| `DEPOSIT_CLI_IMAGE` | `ghcr.io/ethstaker/ethstaker-deposit-cli:latest` | Deposit CLI container image used by `--docker` |
| `DEPOSIT_CLI_RELEASE_VERSION` | `latest` | Deposit CLI Release tag used by `--binary` |

Run `./generate-abpos-validators.sh --help` for the complete interface.

### 4.5 Run the generator again

If the output directory already contains a complete key set, the generator reuses it. If the existing files are incomplete or inconsistent, it stops without overwriting them.

## 5. Deposit data handoff

Back up `mnemonic.txt`, `pwd.txt`, and all keystores before the handoff. Then provide only the deposit data file to the Network Operator through the approved secure channel.

Useful local checks:

```bash
jq 'length' /data/abpos/testnet/keys/validator_keys/deposit_data-*.json
sha256sum /data/abpos/testnet/keys/validator_keys/deposit_data-*.json
```

The Network Operator should record the submitting operator, expected validator count, file checksum, withdrawal address, and accepted network parameters without taking custody of any private key material.

## 6. Build the Genesis Candidate

The Network Operator prepares the configuration, adds every accepted deposit file, and runs the Genesis builder:

```bash
cp -a genesis/config-template genesis/config
vi genesis/config/values.env
```

Set `GENESIS_DELAY` with enough time to collect all node identities and publish the Final Release before the Beacon Genesis time.

Copy every accepted deposit data file into `validator-deposits`. Subdirectories are also supported; the builder recursively reads every `deposit_data-*.json` file below this directory.

```bash
cp /secure/deposits/deposit_data-*.json \
  genesis/config/validator-deposits/
```

```bash
./genesis/generate-abpos-genesis.sh
```

The builder validates the deposit records and writes the public files to `genesis/config/genesis-output`. Review those files before continuing.

Copy the output to the network selected by `CONFIG_NAME`, then create empty node lists for the Candidate:

```bash
source genesis/config/values.env
network="${CONFIG_NAME}"
[[ "${network}" == "testnet" || "${network}" == "mainnet" ]] \
  || { echo "Unsupported CONFIG_NAME: ${network}" >&2; exit 1; }

share_dir="abpos/${network}/share"
mkdir -p "${share_dir}"
cp -a genesis/config/genesis-output/. "${share_dir}/"
touch \
  "${share_dir}/bootstrap_nodes.txt" \
  "${share_dir}/bootstrap_nodes_execution.txt" \
  "${share_dir}/checkpoint_sync_urls.txt"

candidate_tag="v1.0.0-rc.1"
```

`NETWORK_NAME` identifies the chain and is checked against the network name recorded in deposit data. `CONFIG_NAME` selects `abpos/testnet/share` or `abpos/mainnet/share`.

Commit the Candidate files and push a signed Candidate tag. GitHub publishes it as a Pre-release:

```bash
git add "${share_dir}"
git commit -S -m "config: prepare ${network} Genesis Candidate"
git tag -s "${candidate_tag}" -m "AB PoS ${network} Genesis Candidate ${candidate_tag}"
git push origin main "${candidate_tag}"
```

## 7. Collect node information and publish the Final Release

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

The Network Operator adds one consensus ENR per line to `bootstrap_nodes.txt` and one execution enode per line to `bootstrap_nodes_execution.txt`, then commits the lists and pushes the Final tag. GitHub Actions validates the files, builds the artifacts, and publishes the Release. Do not run the Genesis builder again or change any other generated network file.

```bash
source genesis/config/values.env
network="${CONFIG_NAME}"
share_dir="abpos/${network}/share"

vi "${share_dir}/bootstrap_nodes.txt"
vi "${share_dir}/bootstrap_nodes_execution.txt"

make verify-bootnodes NETWORK="${network}"

final_tag="v1.0.0"
git add \
  "${share_dir}/bootstrap_nodes.txt" \
  "${share_dir}/bootstrap_nodes_execution.txt"
git commit -S -m "config: add ${network} Genesis bootstrap nodes"
git tag -s "${final_tag}" -m "AB PoS ${network} ${final_tag}"
git push origin main "${final_tag}"
```

Run the live verification while every submitted node is online. It validates each signed ENR, performs a Discovery v5 ping and resolution, and completes an RLPx handshake with each execution node. The first run builds the local `devp2p` verification tool with Docker.

When a matching Candidate Release exists, the Final Release workflow verifies that only the two node lists changed.

## 8. Start the Final network

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

The installer preserves the chain data, imported validator wallet, fee recipient, JWT, and P2P identities. A fixed checkpoint endpoint may already be included in the Candidate and Final Releases even though it becomes usable only after the network finalizes.

After finalization, verify the endpoint and test the Final Release without `--genesis`. Then mark that Release as the latest GitHub Release. No additional Release is required when its checkpoint URL is already correct.

If the checkpoint URL was absent or must change, add it and publish another stable Release:

```bash
source genesis/config/values.env
network="${CONFIG_NAME}"
share_dir="abpos/${network}/share"

printf '%s\n' 'https://checkpoint.pos.testnet.ab.org' \
  >"${share_dir}/checkpoint_sync_urls.txt"

next_tag="v1.0.1"
git add "${share_dir}/checkpoint_sync_urls.txt"
git commit -S -m "config: publish ${network} checkpoint endpoint"
git tag -s "${next_tag}" -m "AB PoS ${network} ${next_tag}"
git push origin main "${next_tag}"
```

Use the verified checkpoint endpoint for the selected network. After testing the new Release, mark it as the latest GitHub Release.

## 9. Security rules

- Never commit or release mnemonics, passwords, keystores, node private keys, or slashing protection databases.
- Never run one validator pubkey in two validator clients at the same time.
- Verify the Release source, checksum, chain ID, fork versions, genesis validator root, deposit configuration, bootnodes, and checkpoint providers.
- Compare finalized roots from independent trusted sources before selecting a checkpoint.
- Back up slashing protection data before moving validators.
- Treat voluntary exit as irreversible for the exited validator index.

## 10. Current boundaries

This repository does not:

- Decide which submitted deposit records are authorized for a production genesis.
- Replace independent review of the generator image, Genesis source configuration, generated state, or supply calculation.
- Send on-chain deposit transactions.
- Generate or host checkpoints.
- Enforce GPG verification of a Release.
- Back up or migrate slashing protection data.
- Assess whether a checkpoint provider is trustworthy.
- Replace an audited Network Operator genesis build and review process.
