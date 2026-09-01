# AB PoS Genesis Participation and Release Guide

This guide covers the pre-genesis workflow for Genesis Validator Operators and the release workflow for Network Operators. It is intentionally separate from the public [post-genesis node deployment guide](../README.md).

The central security boundary is simple: each Validator Operator keeps all signing material, while the Network Operator receives only public deposit data and publishes only public network material.

## 1. Scripts and lifecycle

| Script | Responsibility | Primary user | Lifecycle stage |
| --- | --- | --- | --- |
| `generate-abpos-validators.sh` | Generate genesis validator secrets, keystores, and deposit data | Genesis Validator Operator | Before genesis is built |
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

- Docker Engine
- Bash
- OpenSSL
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
| `DEPOSIT_CLI_IMAGE` | `ghcr.io/ethstaker/ethstaker-deposit-cli:latest` | Deposit CLI container image |

Run `./generate-abpos-validators.sh --help` for the complete interface.

### 4.5 Idempotency and safety behavior

The generator:

- Creates a random keystore password and mnemonic when they do not exist.
- Validates the withdrawal address and validator count.
- Checks the number of keystores and deposit data files.
- Normalizes the legacy nested `validator_keys/validator_keys` output layout.
- Reuses a complete existing key set instead of generating over it.
- Stops on an incomplete or inconsistent key set.
- Runs the Deposit CLI container with the invoking user's UID and GID.

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

The older `pos-docs` external-deposit branch contains useful validation concepts, but its deployment and key-distribution logic is not part of this public repository. Genesis construction must use a separately reviewed builder workflow.

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
| `jwtsecret` | Yes | Local Engine API authentication material |
| `config.yaml` | Yes | Lighthouse custom network configuration |
| `config.prysm.yaml` | Yes | Prysm custom network configuration |
| `bootstrap_nodes.txt` | Optional | Beacon ENR list, one per line |
| `enodes.txt` | Optional | Geth enode list, one per line |
| `checkpoint_sync_urls.txt` | Required after genesis | Trusted Beacon API checkpoint provider URLs, one per line |

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

This repository follows the packaging pattern used by `ABFoundationGlobal/ab-deploy`. It packages existing public network files; it does not generate them.

Build the initial package before a checkpoint exists:

```bash
make testnet VERSION=v1.0.0 RELEASE_PHASE=genesis
```

In this phase, a missing `checkpoint_sync_urls.txt` produces an informational message. The package is valid only for nodes started with `--genesis`; an ordinary node must provide `--checkpoint-url` explicitly.

After finalization, add at least one verified URL and build the ordinary-node package with strict post-genesis validation:

```bash
make testnet VERSION=v1.0.1 RELEASE_PHASE=post-genesis
```

The post-genesis build fails if `checkpoint_sync_urls.txt` is absent, empty, or contains a non-HTTP(S) entry. Every build also checks the required genesis files, JSON chain ID, JWT encoding, and any published ENR, enode, block-number, and checkpoint entries before creating an archive.

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

Pushing a `v*` tag runs the GitHub Release workflow and uploads the archives and checksums produced by `make`. The tag must reach GitHub; pushing it only to a GitLab remote does not run the workflow under `.github/workflows/`.

### 7.3 Build the patched execution client

The default build pins the current upstream go-ethereum release and applies every patch under `patches/go-ethereum/`:

```bash
make geth
```

The current defaults are:

```text
GETH_VERSION=v1.17.5
AB_GETH_VERSION=v1.17.5-ab.1
GETH_PLATFORM=linux/amd64
```

The build starts from the exact official tag in a generated checkout under `build/src/`. Before applying each patch, it runs `git apply --check`. If the check fails, the build prints the patch path, upstream version, and original Git error, then exits without attempting a fuzzy or partial application.

Outputs include the static binary, SHA256 checksum, and build metadata:

```text
build/ab-geth-v1.17.5-ab.1-linux-amd64
build/ab-geth-v1.17.5-ab.1-linux-amd64.sha256
build/ab-geth-v1.17.5-ab.1-linux-amd64.build-info.txt
```

Build and save the runtime image as a GitHub Release asset:

```bash
make docker
```

This tags `ghcr.io/abdaodev/ab-geth:v1.17.5-ab.1` and `ghcr.io/abdaodev/ab-geth:latest`, then writes a compressed Docker archive and checksum under `build/`. `make` builds the network archive, patched binary, and Docker archive together. `make clean` removes only this repository's generated `build/` directory; it does not remove published files or local Docker images.

The tag workflow uploads all generated artifacts to GitHub Release and pushes both image tags to GitHub Container Registry. Consensus-client compilation is intentionally outside the current build scope.

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

- Combine deposit data or generate `genesis.json` and `genesis.ssz`.
- Send on-chain deposit transactions.
- Generate or host checkpoints.
- Enforce GPG verification of a Release.
- Back up or migrate slashing protection data.
- Assess whether a checkpoint provider is trustworthy.
- Replace an audited Network Operator genesis build and review process.
