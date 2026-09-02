# AB PoS Node Deployment Guide

This repository provides the public deployment entry point for joining an AB PoS network. It supports Geth as the execution client and either Prysm or Lighthouse as the consensus client. Docker is the default deployment method; native binaries are also supported.

## 1. Node types

| Node type | Components | Validator keys | Default sync source |
| --- | --- | --- | --- |
| RPC node | Geth and a beacon node | No | Checkpoint |
| Validator node | Geth, a beacon node, and a validator client | Yes | Checkpoint |
| Archive node | Archive Geth and a beacon node | No | Checkpoint |

## 2. System requirements

### 2.1 Recommended specifications

- Operating system: Ubuntu 24.04 LTS x86_64
- Processor: 2 CPU cores or more
- Memory: 16 GB RAM or more
- Storage: 200 GB or more on an SSD
- Network: A stable internet connection

Archive nodes require substantially more storage, IOPS, and synchronization time.

### 2.2 Required software

- jq
- Docker Engine for Docker deployments

## 3. Deploy a node

Every deployment runs Geth and one beacon node. Validator and archive behavior are optional additions to the same node, so `--validator` and `--archive` may be used separately or together.

### 3.1 RPC node

Deploy Geth with Prysm:

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth
```

Deploy Geth with Lighthouse:

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet lighthouse geth
```

The default command reads its trusted checkpoint provider from `checkpoint_sync_urls.txt` in the selected network Release. To use an explicitly selected provider:

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth \
  --checkpoint-url https://checkpoint.example.org
```

Verify the checkpoint provider through an independent trusted channel before using it.

### 3.2 Add validator duties

A validator deployment creates a new mnemonic, password, keystores, and deposit data when its validator key directory is empty.

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth \
  --validator \
  --validator-count 1000 \
  --withdrawal-address 0x0000000000000000000000000000000000000000 \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Lighthouse uses the same options:

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet lighthouse geth \
  --validator \
  --validator-count 1000 \
  --withdrawal-address 0x0000000000000000000000000000000000000000 \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Replace every example address before running either command.

The default key locations are:

```text
/data/abpos/testnet/
|-- mnemonic.txt
|-- pwd.txt
`-- validator-keys/
    |-- keystore-*.json
    `-- deposit_data-*.json
```

Generating keys and starting a validator client does not complete the staking process. Submit the generated deposit data through the approved on-chain deposit process and wait for the activation queue before expecting validator duties.

Back up the mnemonic, password, keystores, and slashing protection data. Never run the same validator keys in more than one validator client at the same time.

### 3.3 Add archive storage

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet lighthouse geth --archive
```

This starts Geth with full synchronization and archive state retention. It does not start a validator client unless `--validator` is also specified.

### 3.4 Native binary deployment

Add `--binary` to any node command to download and run native client binaries instead of containers:

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth --binary
```

The selected Network Release supplies the patched AB Geth binary. Prysm and Lighthouse binaries are downloaded from their official GitHub Releases. When a non-genesis validator needs new keys, the EthStaker Deposit CLI binary is downloaded from its official GitHub Release. Client binaries are verified before installation under `/data/abpos/<network>/bin/`.

Binary processes run in detached sessions and write logs under `/data/abpos/<network>/logs/`. They are not configured to start automatically after a server reboot.

## 4. Node operations

Use the same network and consensus client that were selected during installation.

For a binary deployment, include `--binary` in each operation command. Without it, operations target the default Docker deployment.

Show node and synchronization status:

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth --status
```

Follow logs:

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth --logs geth
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth --logs beacon
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth --logs validator
```

Stop or restart the node:

```bash
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth --stop
curl -fsSL https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh | sudo bash -s -- testnet prysm geth --restart
```

## 5. Network ports

| Service | Bind address | Port | Protocol | Notes |
| --- | --- | ---: | --- | --- |
| Geth P2P | Public | 30303 | TCP/UDP | Execution-layer peer traffic |
| Geth JSON-RPC | `127.0.0.1` | 8545 | TCP | Local execution API |
| Geth Engine API | `127.0.0.1` | 8551 | TCP | Consensus-to-execution communication |
| Beacon P2P | Public | 13000 | TCP | Consensus-layer peer traffic |
| Beacon discovery | Public | 12000 | UDP | Consensus-layer peer discovery |
| Beacon HTTP API | `127.0.0.1` | 3500 | TCP | Local beacon API and status checks |
| Prysm RPC | `127.0.0.1` | 4000 | TCP | Used by the Prysm validator client |

Allow the public P2P ports through the host firewall. Keep loopback-only APIs private unless an authenticated access-control layer protects them.

## 6. Current limitations

The first version of `ab-pos.sh` has the following known boundaries:

- It does not submit on-chain validator deposits.
- It does not generate checkpoints.
- It does not deploy monitoring, a reverse proxy, TLS, or firewall rules.
- A missing Release checksum produces a warning rather than a hard failure.
- It does not back up or migrate slashing protection data.
- Fixed service identities and ports prevent multiple instances of the same network on one host.
- Binary deployments do not automatically start after a server reboot.
- End-to-end production testing is still required for each supported client and node mode.
