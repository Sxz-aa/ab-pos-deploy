# AB PoS Genesis Participation and Release Guide

This guide covers the pre-genesis workflow for Genesis Validator Operators and the release workflow for Network Operators. It is intentionally separate from the public [post-genesis node deployment guide](../README.md).

The central security boundary is simple: each Validator Operator keeps all signing material, while the Network Operator receives only public deposit data and publishes only public network material.

## 1. Scripts and lifecycle

| Script | Responsibility | Primary user | Lifecycle stage |
| --- | --- | --- | --- |
| `generate-abpos-validators.sh` | Generate genesis validator secrets, keystores, and deposit data | Genesis Validator Operator | Before genesis is built |
| `generate-abpos-genesis.sh` | Build and verify execution and consensus genesis files from accepted deposit data | Network Operator | After deposit data is collected |
| `ab-pos.sh` | Download a network Release and deploy Geth, a beacon node, and optionally a validator client | Node and infrastructure operators | After a Release is published |

`generate-abpos-validators.sh` does not build genesis files or deploy a node. `ab-pos.sh --genesis --validator` does not generate keys; it imports the same keys that were included in the genesis validator set.

## 2. Roles

### 2.1 Network Operator

The Network Operator coordinates public network material:

- Collect `deposit_data-*.json` from all Genesis Validator Operators.
- Validate record format, network parameters, validator counts, amounts, and duplicate pubkeys.
- Build the final `genesis.json` and `genesis.ssz` with an audited genesis toolchain.
- Prepare Prysm and Lighthouse chain configuration.
- Collect stable Geth enodes and beacon ENRs.
- Start initial RPC and bootnodes.
- Publish a verifiable Genesis Release and its SHA256 checksum.
- Publish trusted checkpoint providers after the network finalizes.

The Network Operator must not request or retain another operator's mnemonic, password, keystores, validator signing keys, or slashing protection database.

### 2.2 Genesis Validator Operator

Each Genesis Validator Operator:

- Generates and backs up its own mnemonic.
- Keeps its password and keystores private.
- Sends only deposit data to the Network Operator before genesis.
- Verifies the published network Release.
- Imports the same genesis keystores into exactly one validator client.
- Preserves and backs up slashing protection data.

### 2.3 Infrastructure Operator

An Infrastructure Operator runs public RPC, archive, beacon, checkpoint, monitoring, or explorer services. This role does not require validator keys and does not necessarily participate in staking.

Roles describe responsibility; node types describe software. One organization may perform more than one role without merging their security boundaries.

## 3. End-to-end genesis flow

```text
Genesis Validator Operator
  -> generate mnemonic, password, keystores, and deposit data
  -> back up all private material
  -> send only deposit_data-*.json

Network Operator
  -> validate and combine deposit records
  -> build genesis.json and genesis.ssz
  -> prepare client configuration and bootnodes
  -> publish the initial Genesis Release and checksum

Genesis Validator Operator
  -> verify the Release
  -> run ab-pos.sh --genesis --validator with the original keys
  -> confirm duties and finality

Network Operator
  -> publish trusted checkpoint URLs after finalization
  -> publish a post-genesis Release for ordinary nodes
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
  0x0000000000000000000000000000000000000000
```

Replace the example withdrawal address before running the command.

To use the official EthStaker Deposit CLI binary instead of Docker:

```bash
./generate-abpos-validators.sh --binary \
  0x0000000000000000000000000000000000000000
```

The binary archive and its checksum are downloaded from the selected EthStaker Deposit CLI GitHub Release. The verified executable is installed under `<ABPOS_ROOT_PATH>/bin/`.

The current generator defaults to:

- 1000 validators
- 2048 ETH per validator deposit record
- `0x02` compounding withdrawal credentials
- AB Core devnet chain settings
- `/data/abpos` as the output root

### 4.3 Generated files

```text
/data/abpos/keys/
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
ABPOS_ROOT_PATH=/data/abpos/operator-a \
./generate-abpos-validators.sh \
  0x0000000000000000000000000000000000000000
```

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `WITHDRAWAL_ADDRESS` | None | Used when the positional address is omitted |
| `VALIDATOR_COUNT` | `1000` | Number of validators to generate |
| `ABPOS_ROOT_PATH` | `/data/abpos` | Output root |
| `DEPOSIT_CLI_IMAGE` | `ghcr.io/ethstaker/ethstaker-deposit-cli:latest` | Deposit CLI container image used by `--docker` |
| `DEPOSIT_CLI_RELEASE_VERSION` | `latest` | Deposit CLI Release tag used by `--binary` |

Run `./generate-abpos-validators.sh --help` for the complete interface.

### 4.5 Idempotency and safety behavior

The generator:

- Creates a random keystore password and mnemonic when they do not exist.
- Validates the withdrawal address and validator count.
- Checks the number of keystores and deposit data files.
- Normalizes the legacy nested `validator_keys/validator_keys` output layout.
- Reuses a complete existing key set instead of generating over it.
- Stops on an incomplete or inconsistent key set.
- Runs the Deposit CLI container with the invoking user's UID and GID in Docker mode.
- Verifies the official Deposit CLI archive checksum in binary mode.

It does not build genesis files, send a transaction, upload private material, back up the mnemonic, or start node software.

## 5. Deposit data handoff

Back up `mnemonic.txt`, `pwd.txt`, and all keystores before the handoff. Then provide only the deposit data file to the Network Operator through the approved secure channel.

Useful local checks:

```bash
jq 'length' /data/abpos/keys/validator_keys/deposit_data-*.json
sha256sum /data/abpos/keys/validator_keys/deposit_data-*.json
```

The Network Operator should record the submitting operator, expected validator count, file checksum, withdrawal address, and accepted network parameters without taking custody of any private key material.

## 6. Network Operator validation

Before building genesis, validate every deposit record and the combined set:

- Each input is a non-empty JSON array.
- Every pubkey is correctly encoded and globally unique.
- Withdrawal credentials are correctly encoded and use the intended credential type.
- The amount matches the approved genesis allocation.
- `fork_version` and `network_name` match the AB PoS network configuration.
- Per-operator and total validator counts match the approved allocation.
- The resulting genesis validator pubkeys exactly match the accepted deposit records.
- The execution-layer premine calculation accounts for the actual total validator stake.

The Genesis builder follows the `pos-docs` multi-operator deposit-data workflow. It intentionally omits its client download, SSH deployment, runtime key import, and node-management logic.

The Network Operator workflow is:

1. Copy `genesis/config-template` to `genesis/config`.
2. Review and edit `genesis/config/values.env`.
3. Place all accepted `deposit_data-*.json` files under `genesis/config/validator-deposits`.
4. Run `generate-abpos-genesis.sh` and review `genesis/config/genesis-output`.
5. Start the stable initial nodes and collect their Beacon ENRs and Geth enodes.
6. Place the approved public Genesis files and bootnodes under `abpos/<network>/share` and build the Network Release.

### 6.1 Prepare a Genesis configuration

Copy the reviewed template into the default working directory:

```bash
cp -a genesis/config-template genesis/config
```

Edit `genesis/config/values.env` before each Genesis build. Important values include:

| Variable | Purpose |
| --- | --- |
| `CONFIG_NAME` | Client-facing configuration name |
| `CHAIN_ID` | Execution and deposit chain ID |
| `NUMBER_OF_VALIDATORS` | Approved Genesis Validator count |
| `GENESIS_TIMESTAMP` | EL Genesis timestamp and `MIN_GENESIS_TIME`; `0` selects the current time plus 300 seconds |
| `GENESIS_DELAY` | Delay added to `MIN_GENESIS_TIME` to obtain the Beacon Genesis time |
| `MIN_VALIDATOR_GWEI` / `MAX_VALIDATOR_GWEI` | Accepted deposit amount range |
| `TARGET_TOTAL_SUPPLY_AB` | Intended total AB supply |
| `KAB_MULTIPLIER` | AB represented by one staked ETH |
| `EL_PREMINE_ADDRESS` | Address receiving the calculated EL premine |

In the default deposit-data workflow, each Validator's balance comes from the `amount` in its accepted deposit record. The builder sums those actual amounts when calculating the EL premine.

The checked-in `config-template` remains unchanged. The copied `genesis/config` workspace is ignored by Git and contains the operator's inputs, temporary files, and generated output.

### 6.2 Collect deposit data

Deposit-data mode is the default. Place each operator's accepted deposit file under `genesis/config/validator-deposits`. Subdirectories may separate operators:

```text
genesis/config/
|-- values.env
|-- el/
|-- cl/
`-- validator-deposits/
    |-- operator-a/deposit_data-*.json
    `-- operator-b/deposit_data-*.json
```

### 6.3 Generate Genesis from deposit data

The builder recursively finds every `deposit_data-*.json` file in the workspace and writes public results to `genesis/config/genesis-output`:

```bash
GENESIS_GENERATOR_IMAGE=ethpandaops/ethereum-genesis-generator@sha256:REVIEWED_DIGEST \
./genesis/generate-abpos-genesis.sh
```

The explicit form is equivalent:

```bash
./genesis/generate-abpos-genesis.sh --deposit-data
```

`GENESIS_TIMESTAMP` is `MIN_GENESIS_TIME`, not the final Beacon Genesis time. The configured `GENESIS_DELAY` is added by the consensus generator. An explicit reviewed timestamp should be configured for a coordinated network launch.

The builder:

- Verifies every deposit record's pubkey, withdrawal credentials, amount, fork version, and network name.
- Rejects duplicate pubkeys and validator-count mismatches.
- Recalculates the execution-layer premine from the actual total genesis stake.
- Generates a new `genesis.json` from the workspace's `el/genesis-config.yaml`; it does not copy an existing network Genesis.
- Removes the generator's reserved allocations from `0x0000000000000000000000000000000000000000` through `0x00000000000000000000000000000000000000ff`.
- Generates `genesis.ssz` from that final `genesis.json` and the accepted public validator set.
- Verifies that the generated validator pubkey set exactly matches the accepted deposit data.
- Produces `deposit_contract.txt`, `deposit_contract_block_hash.txt`, and `genesis_validators_root.txt` alongside the client configuration.
- Never reads validator keystores and never publishes or copies a JWT secret.

Use `--config /path/to/config` to select a different prepared workspace. This does not couple the builder to an existing `testnet` or `mainnet` share.

Review the generator image digest, source configuration, timestamp, premine calculation, fork schedule, and generated roots independently before copying approved output into `abpos/<network>/share`. Bootnodes are collected separately from the stable initial nodes; they are not generated or copied by the Genesis Builder.

## 7. Prepare the network Release

After generating and independently verifying the final public network files, place them under:

```text
abpos/<network>/share/
```

The current installer consumes the following files:

| File | Required by installer | Purpose |
| --- | --- | --- |
| `genesis.json` | Yes | Geth genesis |
| `genesis.ssz` | Yes | Consensus genesis state |
| `config.yaml` | Yes | Lighthouse custom network configuration |
| `config.prysm.yaml` | Yes | Prysm custom network configuration |
| `deposit_contract.txt` | No | Public deposit contract address for tooling and verification |
| `deposit_contract_block.txt` | Yes | Execution-layer deposit contract deployment block used by Lighthouse |
| `deposit_contract_block_hash.txt` | No | Deposit contract deployment block hash |
| `genesis_validators_root.txt` | No | Published consensus genesis validators root |
| `bootstrap_nodes.txt` | Yes | Beacon ENR list, one per line |
| `bootstrap_nodes_execution.txt` | Yes | Geth enode list, one per line |
| `checkpoint_sync_urls.txt` | Required after genesis | Trusted Beacon API checkpoint provider URLs, one per line |

Do not include `jwtsecret` in the network share or Release. The installer generates a private JWT secret under each node's data directory and supplies the same local file to its execution and consensus clients.

The installer requires an explicit `--checkpoint-url` when `checkpoint_sync_urls.txt` is absent and the node is not using `--genesis`.

`checkpoint_sync_urls.txt` is a UTF-8 text file. Put one complete HTTP or HTTPS Beacon checkpoint endpoint on each line. Blank lines and lines whose first non-whitespace character is `#` are ignored. The installer currently selects the first usable URL:

```text
# Trusted Beacon checkpoint providers
https://checkpoint-1.example.org
https://checkpoint-2.example.org
```

The URL must point to a compatible Beacon API checkpoint-sync service, not an execution-layer JSON-RPC endpoint. Verify its finalized root through an independent trusted source before publishing it.

### 7.1 Two-release lifecycle

1. The initial Genesis Release contains the verified genesis files and bootnodes. A finalized checkpoint does not exist yet.
2. Genesis nodes start with `--genesis`.
3. After the network finalizes, the Network Operator publishes trusted checkpoint provider URLs.
4. A newer post-genesis Release includes `checkpoint_sync_urls.txt` and becomes the default Release for ordinary RPC, validator, and archive nodes.

Do not advertise the default post-genesis command until the latest Release contains a working trusted checkpoint URL.

### 7.2 Build release artifacts

This repository follows the packaging pattern used by `ABFoundationGlobal/ab-deploy`. The Genesis Builder produces candidate public network files; `make network` packages only the files that the Network Operator has reviewed and placed under `abpos/<network>/share`.

Build the initial package before a checkpoint exists:

```bash
make testnet VERSION=v1.0.0 RELEASE_PHASE=genesis
```

In this phase, a missing `checkpoint_sync_urls.txt` produces an informational message. The package is valid only for nodes started with `--genesis`; an ordinary node must provide `--checkpoint-url` explicitly.

After finalization, add at least one verified URL and build the ordinary-node package with strict post-genesis validation:

```bash
make testnet VERSION=v1.0.1 RELEASE_PHASE=post-genesis
```

The post-genesis build fails if `checkpoint_sync_urls.txt` is absent, empty, or contains a non-HTTP(S) entry. Every build also checks the required genesis files, JSON chain ID, deposit configuration, fork configuration, and any published ENR, enode, block-number, root, hash, and checkpoint entries before creating an archive.

Output:

```text
build/
|-- abpos-testnet-v1.0.0.tar.gz
`-- abpos-testnet-v1.0.0.tar.gz.sha256
```

Verify the local artifact before publication:

```bash
cd build
sha256sum --check abpos-testnet-v1.0.0.tar.gz.sha256
```

Publish a signed version tag to the GitHub repository:

```bash
git tag -s v1.0.0 -m "AB PoS testnet v1.0.0"
git push <github-remote> v1.0.0
```

Pushing a `v*` tag runs the GitHub Release workflow and publishes the files required by that Network Release. The tag must reach GitHub; pushing it only to a GitLab remote does not run the workflow under `.github/workflows/`.

## 8. Start genesis nodes after publication

### 8.1 Genesis RPC node

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --genesis
```

This initializes Geth and the beacon node from the published genesis files without starting a validator client.

### 8.2 Genesis validator node

Use the same keystores that were represented in the accepted genesis deposit data:

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --genesis \
  --validator \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

The default inputs are:

```text
/data/abpos/keys/validator_keys/
/data/abpos/keys/pwd.txt
```

Override them when necessary:

```bash
sudo ./ab-pos.sh testnet lighthouse geth \
  --genesis \
  --validator \
  --keys-dir /secure/operator-a/validator_keys \
  --password-file /secure/operator-a/pwd.txt \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Genesis validator mode refuses to generate replacement keys. Newly generated pubkeys would not exist in `genesis.ssz` and could not act as genesis validators.

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
