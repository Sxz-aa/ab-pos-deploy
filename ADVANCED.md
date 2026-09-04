# Advanced AB PoS Deployment Guide

This guide covers source builds, local installation, pinned Releases, client overrides, upgrades, and custom data layouts. The main [README](README.md) remains the ordinary node installation guide. Repository maintainers publishing artifacts should also read [BUILD.md](BUILD.md).

## 1. Build from source

Clone the repository and run the default build:

```bash
git clone https://github.com/abdaodev/ab-pos-deploy.git
cd ab-pos-deploy
make
```

The default `make` target performs three operations:

1. Validates and packages the AB Core Testnet network files.
2. Builds the patched AB Geth binary.
3. Builds the exact-version AB Geth Docker image in the local Docker daemon.

The default build settings come from the `Makefile`:

```text
CHAIN=abcore
NETWORK=testnet
RELEASE_PHASE=release
GETH_VERSION=v1.17.5
AB_GETH_VERSION=v1.17.5-ab.1
GETH_PLATFORM=linux/amd64
```

`VERSION` defaults to `git describe --tags --always --dirty`. It controls the network archive filename; it does not control the AB Geth version.

Inspect the generated files and image:

```bash
ls -lh build/
make -s geth-version
docker image inspect \
  "ghcr.io/abdaodev/ab-geth:$(make -s geth-version)"
```

`make` does not push an image, move `latest`, or create a GitHub Release.

### 1.1 Individual build targets

```bash
make check       # Validate network files and build inputs
make network     # Create the network archive and checksum
make geth        # Build the patched AB Geth binary and checksum
make docker      # Build the exact-version image in the local Docker daemon
make clean       # Remove this repository's build/ directory
```

Use a fixed archive version when a predictable local filename is useful:

```bash
make network VERSION=local
```

This produces:

```text
build/abcore-testnet-local.tar.gz
build/abcore-testnet-local.tar.gz.sha256
```

The fixed version is optional. A normal `make` build is sufficient.

### 1.2 Checkpoint configuration

The default `release` mode validates a checkpoint URL when the network share contains one:

```bash
make network RELEASE_PHASE=release
```

The file is optional. Without it, non-genesis nodes must provide `--checkpoint-url` when installing.

## 2. Install from a local Docker build

After `make`, identify the network archive printed by the build. If the `build/` directory contains multiple old archives, select the one created by the current build explicitly.

```bash
network_archive="$(ls -1t "$PWD"/build/abcore-testnet-*.tar.gz | head -n 1)"
geth_tag="$(make -s geth-version)"

printf 'Network archive: %s\n' "$network_archive"
printf 'AB Geth image:   %s\n' \
  "ghcr.io/abdaodev/ab-geth:${geth_tag}"
```

Install a Genesis RPC node with the locally built AB Geth image:

```bash
sudo env \
  GETH_DOCKER_IMAGE="ghcr.io/abdaodev/ab-geth:${geth_tag}" \
  ./ab-pos.sh testnet prysm geth \
    --docker \
    --genesis \
    --release-url "file://${network_archive}"
```

Use `lighthouse` instead of `prysm` to select Lighthouse.

For a post-genesis node, omit `--genesis`. The archive must contain a checkpoint URL, or the command must specify one:

```bash
sudo env \
  GETH_DOCKER_IMAGE="ghcr.io/abdaodev/ab-geth:${geth_tag}" \
  ./ab-pos.sh testnet prysm geth \
    --docker \
    --release-url "file://${network_archive}" \
    --checkpoint-url https://checkpoint.example.org
```

`--release-url` bypasses the GitHub Release API. Docker mode therefore requires `GETH_DOCKER_IMAGE` to identify the exact local or remote AB Geth image that belongs with the network archive.

Prysm or Lighthouse is still pulled from its configured public container registry when its image is not already present locally.

### 2.1 Docker daemon visibility

The image produced by `make docker` exists only in the Docker daemon used for the build. The installer must use the same daemon.

On a normal Ubuntu system with the system Docker daemon, building as a user in the `docker` group and installing with `sudo` normally uses the same daemon. A rootless Docker image is not visible to the root-owned Docker daemon. For rootless Docker, run the installer without `sudo` and select a user-writable data directory:

```bash
GETH_DOCKER_IMAGE="ghcr.io/abdaodev/ab-geth:${geth_tag}" \
./ab-pos.sh testnet prysm geth \
  --docker \
  --genesis \
  --data-dir "$PWD/abcore-testnet-data" \
  --release-url "file://${network_archive}"
```

## 3. Install from local binaries

`make geth` creates a static patched AB Geth binary and checksum:

```text
build/ab-geth-v1.17.5-ab.1-linux-amd64
build/ab-geth-v1.17.5-ab.1-linux-amd64.sha256
```

Install a native-binary Genesis node from the local artifacts:

```bash
network_archive="$(ls -1t "$PWD"/build/abcore-testnet-*.tar.gz | head -n 1)"
geth_tag="$(make -s geth-version)"
geth_binary="$PWD/build/ab-geth-${geth_tag}-linux-amd64"

sudo env \
  AB_GETH_BINARY_URL="file://${geth_binary}" \
  AB_GETH_BINARY_SHA256_URL="file://${geth_binary}.sha256" \
  ./ab-pos.sh testnet prysm geth \
    --binary \
    --genesis \
    --release-url "file://${network_archive}"
```

The installer verifies the AB Geth checksum before replacing the installed executable. Prysm and Lighthouse binaries are downloaded from their official Releases and verified before installation.

Binary processes run in detached sessions through `setsid`. They are not automatically configured to start after a server reboot.

## 4. Select a Network Release

The installer supports four Release selection patterns.

### 4.1 Latest published Release

```bash
sudo ./ab-pos.sh testnet prysm geth
```

This resolves the latest non-draft, non-prerelease GitHub Release through the repository's `/releases/latest` endpoint.

### 4.2 Pinned Release tag

```bash
sudo ./ab-pos.sh testnet prysm geth --release v1.2.3
```

Pinning a tag makes repeated deployment deterministic as long as published assets and exact image tags remain immutable.

A Genesis Candidate is a Pre-release and is never returned by `/releases/latest`. Genesis participants must select its exact `vMAJOR.MINOR.PATCH-rc.NUMBER` tag with `--release`.

### 4.3 Different Release repository

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --release-repo OWNER/REPOSITORY \
  --release v1.2.3
```

### 4.4 Direct archive URL

Docker mode requires both the archive and an exact image reference:

```bash
sudo env GETH_DOCKER_IMAGE=ghcr.io/example/ab-geth:v1.17.5-ab.1 \
  ./ab-pos.sh testnet prysm geth \
    --release-url https://example.org/abcore-testnet-v1.2.3.tar.gz
```

Binary mode requires the archive, AB Geth binary, and checksum URLs:

```bash
sudo env \
  AB_GETH_BINARY_URL=https://example.org/ab-geth-v1.17.5-ab.1-linux-amd64 \
  AB_GETH_BINARY_SHA256_URL=https://example.org/ab-geth-v1.17.5-ab.1-linux-amd64.sha256 \
  ./ab-pos.sh testnet prysm geth \
    --binary \
    --release-url https://example.org/abcore-testnet-v1.2.3.tar.gz
```

The installer looks for the archive checksum at `<release-url>.sha256`.

## 5. Repeat installation and upgrade

Re-run the same installation command to apply a newer selected Network Release or AB Geth version. Keep all original node-mode options, including `--validator`, `--archive`, `--binary`, and any custom paths.

During each installation run, the script:

1. Resolves and downloads the selected Network Release.
2. Verifies its checksum when the checksum is available.
3. Extracts and validates it in a temporary directory.
4. Replaces the public `share/` directory without mixing old and new files.
5. Preserves execution data, consensus data, validator data, keys, JWT, and logs.
6. Stops the running clients.
7. Runs `geth init` with the updated `genesis.json` even when chaindata already exists.
8. Recreates the launch configuration and restarts the selected services.

Re-running `geth init` is required for execution-layer hard-fork configuration updates. Geth accepts a compatible updated chain configuration when the Genesis block hash remains unchanged. It rejects a different Genesis block or a fork configuration that conflicts with the imported chain.

For an execution hard fork, publish the future fork settings in `genesis.json` before activation. Do not change fields that alter the actual Genesis block, such as its allocation or header values.

Consensus fork settings are supplied through `config.yaml` and `config.prysm.yaml`. `genesis.ssz` remains the original consensus Genesis state for the network.

### 5.1 Docker client updates

AB Geth uses the exact version tag derived from the selected Network Release. A new exact tag is pulled automatically when it is not present locally.

Prysm `stable` and Lighthouse `latest` are mutable defaults. Docker does not refresh an already cached mutable tag merely because a container is recreated. Pull the selected consensus image before repeating the installation command when an explicit consensus-client update is required:

```bash
docker pull offchainlabs/prysm-beacon-chain:stable
docker pull offchainlabs/prysm-validator:stable   # Validator nodes only
```

or:

```bash
docker pull sigp/lighthouse:latest
```

Production operators may override these defaults with reviewed, pinned image tags:

```bash
sudo env \
  PRYSM_BEACON_IMAGE=offchainlabs/prysm-beacon-chain:REVIEWED_TAG \
  PRYSM_VALIDATOR_IMAGE=offchainlabs/prysm-validator:REVIEWED_TAG \
  ./ab-pos.sh testnet prysm geth
```

For Lighthouse:

```bash
sudo env LIGHTHOUSE_IMAGE=sigp/lighthouse:REVIEWED_TAG \
  ./ab-pos.sh testnet lighthouse geth
```

## 6. Custom data and key locations

The default network data directory is:

```text
/data/<chain>/<network>/
```

Important subdirectories and files include:

```text
/data/abcore/testnet/
|-- share/                  Public Network Release files
|-- geth/                   Execution-layer database
|-- prysm/ or lighthouse/   Beacon database
|-- *-validator/            Validator client and slashing data
|-- keys/                   Validator keys and Deposit Data
|-- bin/                    Native binaries
|-- run/                    Native launchers and PID files
|-- logs/                   Native client logs
`-- config/                 Node identity and Engine API authentication
    |-- jwtsecret
    |-- execution/geth/nodekey
    `-- consensus/
        |-- prysm/p2p.key
        `-- lighthouse/network/
```

The installer keeps node identity files outside the execution and beacon databases. Deleting a client database for a resync therefore does not change the node's execution enode or consensus peer ID. Existing installations are migrated automatically the next time the installer runs.

Override the entire network directory:

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --data-dir /mnt/fast-disk/abcore-testnet
```

Override Genesis Validator key inputs:

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --genesis \
  --validator \
  --keys-dir /secure/validator_keys \
  --password-file /secure/pwd.txt \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Never run the same validator pubkey from two validator clients. Preserve the validator client data directory when upgrading because it contains slashing protection state.

### 6.1 Validator key generation and import

Key generation, key import, and synchronization source are independent:

| Command options | Result |
| --- | --- |
| `--generate-keys` | Generate keys and Deposit Data, then exit without changing node services. |
| `--generate-keys --validator` | Generate a batch, import it, and deploy the Validator Client with the node. |
| `--validator` | Run the Validator Client. If its wallet is empty, import existing keystores; otherwise reuse the existing wallet. |
| `--import-keys` | Import all keystores not already present and restart only the installed Validator Client. |
| `--genesis` | Synchronize the node from Genesis. It does not generate or select keys. |

Key-generation options:

| Option | Default | Behavior |
| --- | --- | --- |
| `--validator-count` | `1000` | Number of keys in the new batch. |
| `--validator-start-index` | `0` | First derivation index used with the selected mnemonic. |
| `--mnemonic-file` | `<data-dir>/keys/mnemonic.txt` | Reuse this mnemonic when it exists; otherwise create it. |
| `--keys-dir` | `<data-dir>/keys/validator_keys` | Shared keystore and Deposit Data directory. For generation, its final component must be `validator_keys`. |
| `--password-file` | `<data-dir>/keys/pwd.txt` | Password shared by keystores in the selected key directory. |
| `--amount` | None | Required for generation. Positive whole-token Deposit amount per Validator. |
| `--withdrawal-address` | None | Required for generation. Withdrawal address encoded in the new Deposit Data. |
| `--fee-recipient` | Saved value | Required only when deploying the Validator Client and no saved value exists. |

Key-only generation reads `deposit-settings.json` from the latest Network
Release by default. Use `--release` to pin a Release or `--deposit-settings`
to use a reviewed local file.

To continue the default mnemonic after a 1000-key batch:

```bash
sudo bash ab-pos.sh testnet \
  --generate-keys \
  --validator-count 1000 \
  --validator-start-index 1000 \
  --amount 2048000 \
  --withdrawal-address 0x0000000000000000000000000000000000000000
```

To create a separate mnemonic, select another mnemonic filename. Its first
batch may start at index zero while sharing the canonical keystore directory:

```bash
sudo bash ab-pos.sh testnet \
  --generate-keys \
  --mnemonic-file /data/abcore/testnet/keys/mnemonic-2.txt \
  --validator-count 1000 \
  --validator-start-index 0 \
  --amount 2048000 \
  --withdrawal-address 0x0000000000000000000000000000000000000000
```

Use one keystore password for all keystores in a shared key directory. The
generator writes directly to that directory, checks only the new files, and
removes the new batch if its pubkeys overlap existing keys. It does not store
or infer the next derivation index.

After key-only generation on an installed Validator node, import the batch:

```bash
sudo bash ab-pos.sh testnet --import-keys
```

For a binary deployment, add `--binary`. This operation leaves Geth and the
Beacon Node running and restarts only the Validator Client.

For the current AB Core configuration, `--amount 32000` is the minimum
activation amount and `--amount 2048000` creates a 2,048,000 AB Deposit record
for each Validator. The installer reads the conversion from the selected
Network Release and verifies the generated Deposit Data. It does not assign a
default amount.

### 6.2 Genesis node public IP

For every `--genesis` deployment, the installer detects the server's public IPv4 address through the same OpenDNS lookup used by the AB deployment tooling. It configures that address for both the execution and consensus clients and prints the resulting execution enode and consensus ENR when installation finishes.

If the displayed address is not the public address through which peers reach this server, repeat the same installation command with an explicit address:

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --genesis \
  --public-ip 203.0.113.10
```

The public firewall or cloud security group must allow Geth TCP/UDP port `30303`, Prysm TCP port `13000`, Prysm discovery UDP port `12000`, and Prysm QUIC UDP port `13000`. The same consensus ports are used by the installer for Lighthouse.

## 7. Advanced operations

Use the same deployment mode used for installation.

Docker status and logs:

```bash
sudo ./ab-pos.sh testnet --status
sudo ./ab-pos.sh testnet --logs geth
sudo ./ab-pos.sh testnet --logs beacon
sudo ./ab-pos.sh testnet --logs validator
```

Binary status and logs:

```bash
sudo ./ab-pos.sh testnet --binary --status
sudo ./ab-pos.sh testnet --binary --logs geth
```

Stop or restart:

```bash
sudo ./ab-pos.sh testnet --stop
sudo ./ab-pos.sh testnet --restart
```

For binary deployments, include `--binary` in both commands.

## 8. Current limitations

`ab-pos.sh` has the following known boundaries:

- It does not submit on-chain validator deposits.
- It does not generate checkpoints.
- It does not deploy monitoring, a reverse proxy, TLS, or firewall rules.
- A missing Release checksum produces a warning rather than a hard failure.
- It does not back up or migrate slashing protection data.
- Fixed service identities and ports prevent multiple instances of the same network on one host.
- Binary deployments do not automatically start after a server reboot.
- End-to-end production testing is still required for each supported client and node mode.

## 9. Before production use

- Pin and review the Network Release tag.
- Verify the archive and AB Geth checksums.
- Pin reviewed consensus-client images or binary versions.
- Back up validator keys, passwords, mnemonic, and slashing protection data.
- Confirm that only one validator client can use each pubkey.
- Verify fork settings and activation times before re-running the installer for a hard fork.
- Verify checkpoint finalized roots through independent trusted sources.
- Test the complete upgrade and rollback procedure on a non-production node first.
