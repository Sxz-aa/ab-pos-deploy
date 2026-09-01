# AB PoS Node Deployment Guide

This repository provides Docker-based deployment scripts and network configuration for AB PoS nodes. It supports Geth as the execution client and either Prysm or Lighthouse as the consensus client.

## 1. System requirements

### 1.1 Recommended specifications

- Operating system: Ubuntu 24.04 LTS x86_64
- Processor: 2 CPU cores or more
- Memory: 16 GB RAM or more
- Storage: 200 GB or more on an SSD
- Network: A stable internet connection; a public IP address is recommended for public P2P nodes

Archive nodes require substantially more storage than standard full nodes.

### 1.2 Required software

- Docker Engine
- Bash
- curl
- jq
- OpenSSL
- tar, find, and sha256sum

The default data root is `/data/abpos`. Mount the system data disk at `/data`, or use `--root-dir` to select another location.

## 2. Installation and deployment

### 2.1 Download the deployment scripts

```bash
mkdir -p ab-pos && cd ab-pos

curl -fLO https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh
curl -fLO https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/generate-abpos-validators.sh

chmod +x ab-pos.sh generate-abpos-validators.sh
```

The installer downloads the selected network configuration from the latest GitHub Release by default. Use `--release`, `--release-url`, or `--release-repo` to select a different release source.

### 2.2 Deploy an RPC node

Synchronize a Prysm node from a checkpoint:

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --checkpoint-url https://checkpoint.example.org
```

Synchronize a Lighthouse node from a checkpoint:

```bash
sudo ./ab-pos.sh testnet lighthouse geth \
  --checkpoint-url https://checkpoint.example.org
```

The `--checkpoint-url` option can be omitted when the selected network Release contains a valid `checkpoint_sync_urls.txt` file.

To synchronize from genesis instead:

```bash
sudo ./ab-pos.sh testnet prysm geth --genesis
```

Add `--archive` to run Geth in archive mode.

### 2.3 Deploy a new validator node

A non-genesis validator deployment generates validator keys when its key directory is empty. Both the withdrawal address and fee recipient are required:

```bash
sudo ./ab-pos.sh testnet lighthouse geth \
  --validator \
  --withdrawal-address 0x0000000000000000000000000000000000000000 \
  --fee-recipient 0x0000000000000000000000000000000000000000 \
  --checkpoint-url https://checkpoint.example.org
```

Replace all example values before running the command. After generation, submit the resulting `deposit_data-*.json` file through the approved network deposit process before expecting the validators to become active.

### 2.4 Deploy a genesis validator node

Generate the validator keys first:

```bash
sudo ./generate-abpos-validators.sh \
  0x0000000000000000000000000000000000000000
```

The default validator count is 1000. Override it with `VALIDATOR_COUNT`:

```bash
sudo VALIDATOR_COUNT=10 ./generate-abpos-validators.sh \
  0x0000000000000000000000000000000000000000
```

Then import the existing keys and start the genesis validator node:

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --genesis \
  --validator \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Genesis validator mode never generates keys. By default, it expects keystores under `/data/abpos/keys/validator_keys` and the password file at `/data/abpos/keys/pwd.txt`.

## 3. Network ports

| Service | Bind address | Port | Protocol | Notes |
| --- | --- | ---: | --- | --- |
| Geth P2P | Public | 30303 | TCP/UDP | Execution-layer peer traffic |
| Geth JSON-RPC | `127.0.0.1` | 8545 | TCP | Local execution API |
| Geth Engine API | `127.0.0.1` | 8551 | TCP | Consensus-to-execution communication |
| Beacon P2P | Public | 13000 | TCP | Consensus-layer peer traffic |
| Beacon discovery | Public | 12000 | UDP | Consensus-layer peer discovery |
| Beacon HTTP API | `127.0.0.1` | 3500 | TCP | Local beacon API and status checks |
| Prysm RPC | `127.0.0.1` | 4000 | TCP | Used by the Prysm validator client |

Allow the public P2P ports through the host firewall. Keep the loopback-only APIs private unless they are protected by an authenticated reverse proxy or another access-control layer.

## 4. Node operations

Use the same network and client selection that was used during installation.

Show container and synchronization status:

```bash
sudo ./ab-pos.sh testnet prysm geth --status
```

Follow logs:

```bash
sudo ./ab-pos.sh testnet prysm geth --logs geth
sudo ./ab-pos.sh testnet prysm geth --logs beacon
sudo ./ab-pos.sh testnet prysm geth --logs validator
```

Stop or restart the node:

```bash
sudo ./ab-pos.sh testnet prysm geth --stop
sudo ./ab-pos.sh testnet prysm geth --restart
```

Run `./ab-pos.sh --help` for the complete option reference.

## 5. Repository layout

```text
.
|-- ab-pos.sh
|-- generate-abpos-validators.sh
`-- abpos
    `-- testnet
        `-- share
            |-- bootstrap_nodes.txt
            |-- config.prysm.yaml
            |-- config.yaml
            |-- deploy_block.txt
            |-- deposit_contract_block.txt
            |-- enodes.txt
            |-- genesis.json
            |-- genesis.ssz
            `-- jwtsecret
```

## 6. Validator key security

- Back up `mnemonic.txt` offline and never share it.
- Never share `pwd.txt` or validator keystores.
- Share only `deposit_data-*.json` with authorized network operations staff.
- Restrict access to `/data/abpos/keys` and its backups.
- Confirm the withdrawal address and fee recipient before creating or importing validator keys.
