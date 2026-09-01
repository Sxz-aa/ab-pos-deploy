# AB PoS Node Deployment Guide

This repository provides the public Docker deployment entry point for joining an AB PoS network after genesis. It supports Geth as the execution client and either Prysm or Lighthouse as the consensus client.

The normal workflow in this guide assumes that the network has already started, finalized a checkpoint, and published a network Release. Genesis participants and Network Operators should use the separate [Genesis Participation and Release Guide](genesis/README.md).

## 1. Node types

| Node type | Components | Validator keys | Default sync source |
| --- | --- | --- | --- |
| RPC node | Geth and a beacon node | No | Checkpoint |
| Validator node | Geth, a beacon node, and a validator client | Yes | Checkpoint |
| Archive node | Archive Geth and a beacon node | No | Checkpoint |

Genesis is a startup method, not a separate node type. The public post-genesis commands below intentionally do not use `--genesis`.

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
- Bash
- curl
- jq
- OpenSSL
- tar, find, and sha256sum

The default data root is `/data/abpos`. Mount the system data disk at `/data`, or use `--root-dir` to select another location.

## 3. Install the deployment script

```bash
mkdir -p ab-pos && cd ab-pos

curl -fLO https://raw.githubusercontent.com/abdaodev/ab-pos-deploy/main/ab-pos.sh
chmod +x ab-pos.sh
```

The installer downloads the selected network archive from the latest GitHub Release in `abdaodev/ab-pos-deploy`. Override the source with `--release-repo`, `--release`, or `--release-url` when required.

## 4. Deploy an RPC node

Deploy Geth with Prysm:

```bash
sudo ./ab-pos.sh testnet prysm geth
```

Deploy Geth with Lighthouse:

```bash
sudo ./ab-pos.sh testnet lighthouse geth
```

The default command reads its trusted checkpoint provider from `checkpoint_sync_urls.txt` in the selected network Release. To use an explicitly selected provider:

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --checkpoint-url https://checkpoint.example.org
```

Verify the checkpoint provider through an independent trusted channel before using it.

## 5. Deploy a validator node

A post-genesis validator deployment creates a new mnemonic, password, keystores, and deposit data when its validator key directory is empty.

```bash
sudo ./ab-pos.sh testnet prysm geth \
  --validator \
  --validator-count 1000 \
  --withdrawal-address 0x0000000000000000000000000000000000000000 \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Lighthouse uses the same options:

```bash
sudo ./ab-pos.sh testnet lighthouse geth \
  --validator \
  --validator-count 1000 \
  --withdrawal-address 0x0000000000000000000000000000000000000000 \
  --fee-recipient 0x0000000000000000000000000000000000000000
```

Replace every example address and IP before running either command.

The default post-genesis key locations are:

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

## 6. Deploy an archive node

```bash
sudo ./ab-pos.sh testnet lighthouse geth --archive
```

This starts Geth with full synchronization and archive state retention. It does not start a validator client unless `--validator` is also specified.

## 7. Node operations

Use the same network and consensus client that were selected during installation.

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

## 8. Network ports

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

## 9. Current limitations

The first version of `ab-pos.sh` has the following known boundaries:

- It does not submit on-chain validator deposits.
- It does not generate genesis files or checkpoints.
- It does not deploy monitoring, a reverse proxy, TLS, or firewall rules.
- `--binary` is reserved and not implemented.
- A missing Release checksum produces a warning rather than a hard failure.
- It does not back up or migrate slashing protection data.
- Fixed container names and ports prevent multiple instances of the same network on one host.
- End-to-end production testing is still required for each supported client and node mode.

## 10. Genesis participation

Do not generate genesis keys with the post-genesis validator workflow. Genesis validator keys must exist before the network genesis state is built. See [genesis/README.md](genesis/README.md) for the multi-operator process, key-generation boundary, public deposit data handoff, network Release lifecycle, and genesis node startup.
