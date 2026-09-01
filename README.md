# AB PoS Node Deployment Guide

This repository provides the public Docker deployment entry point for joining an AB PoS network. It supports Geth as the execution client and either Prysm or Lighthouse as the consensus client.

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
- Network: A stable internet connection and a public IP address for public P2P participation

Archive nodes require substantially more storage, IOPS, and synchronization time.

### 2.2 Required software

- Docker Engine
- jq

Docker must be running and accessible to the current user:

```bash
docker info
```

The default data root is `/data/abpos`. Prepare it once and give the current user ownership:

```bash
sudo mkdir -p /data/abpos
sudo chown "$(id -u):$(id -g)" /data/abpos
```

This setup is the only command in this guide that normally needs `sudo`. To avoid it entirely, select a user-writable location when deploying:

```bash
./ab-pos.sh testnet prysm geth --root-dir "$PWD/abpos-data"
```

## 3. Install the deployment script

```bash
mkdir -p ab-pos && cd ab-pos

curl -fLO https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh
chmod +x ab-pos.sh
```

The installer downloads the selected network archive from the latest GitHub Release in `abdaodev/ab-pos-deploy`. Override the source with `--release-repo`, `--release`, or `--release-url` when required.

## 4. Deploy a node

Every deployment runs Geth and one beacon node. Validator and archive behavior are optional additions to the same node, so `--validator` and `--archive` may be used separately or together.

### 4.1 RPC node

Deploy Geth with Prysm:

```bash
./ab-pos.sh testnet prysm geth
```

Deploy Geth with Lighthouse:

```bash
./ab-pos.sh testnet lighthouse geth
```

The default command reads its trusted checkpoint provider from `checkpoint_sync_urls.txt` in the selected network Release. To use an explicitly selected provider:

```bash
./ab-pos.sh testnet prysm geth \
  --checkpoint-url https://checkpoint.example.org
```

Verify the checkpoint provider through an independent trusted channel before using it.

### 4.2 Add validator duties

A validator deployment creates a new mnemonic, password, keystores, and deposit data when its validator key directory is empty.

```bash
./ab-pos.sh testnet prysm geth \
  --validator \
  --validator-count 1000 \
  --withdrawal-address 0x0000000000000000000000000000000000000000 \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Lighthouse uses the same options:

```bash
./ab-pos.sh testnet lighthouse geth \
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

### 4.3 Add archive storage

```bash
./ab-pos.sh testnet lighthouse geth --archive
```

This starts Geth with full synchronization and archive state retention. It does not start a validator client unless `--validator` is also specified.

### 4.4 Combine validator and archive modes

To run the validator client and retain archive execution state on the same node, combine both flags:

```bash
./ab-pos.sh testnet lighthouse geth \
  --validator \
  --archive \
  --validator-count 1000 \
  --withdrawal-address 0x0000000000000000000000000000000000000000 \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

This combined mode has the archive node's additional storage and IOPS requirements.

## 5. Node operations

Use the same network and consensus client that were selected during installation.

Show container and synchronization status:

```bash
./ab-pos.sh testnet prysm geth --status
```

Follow logs:

```bash
./ab-pos.sh testnet prysm geth --logs geth
./ab-pos.sh testnet prysm geth --logs beacon
./ab-pos.sh testnet prysm geth --logs validator
```

Stop or restart the node:

```bash
./ab-pos.sh testnet prysm geth --stop
./ab-pos.sh testnet prysm geth --restart
```

Run `./ab-pos.sh --help` for the complete option reference.

## 6. Network ports

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

## 7. Current limitations

The first version of `ab-pos.sh` has the following known boundaries:

- It does not submit on-chain validator deposits.
- It does not generate checkpoints.
- It does not deploy monitoring, a reverse proxy, TLS, or firewall rules.
- `--binary` is reserved and not implemented.
- A missing Release checksum produces a warning rather than a hard failure.
- It does not back up or migrate slashing protection data.
- Fixed container names and ports prevent multiple instances of the same network on one host.
- End-to-end production testing is still required for each supported client and node mode.
