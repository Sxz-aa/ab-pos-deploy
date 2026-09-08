# AB PoS Build and Release Guide

This document is for repository maintainers who build Network Release assets, AB Geth, and AB Lighthouse.

## Versioning

The repository uses one Network Release tag, such as `v1.2.3`. The tagged source tree pins all build and runtime client versions in the `Makefile`:

```make
GETH_VERSION ?= v1.17.5
AB_GETH_VERSION ?= $(GETH_VERSION)-ab.1
PRYSM_VERSION ?= v7.1.8
LIGHTHOUSE_VERSION ?= v8.2.2
AB_LIGHTHOUSE_VERSION ?= $(LIGHTHOUSE_VERSION)-ab.1
DEPOSIT_CLI_VERSION ?= v1.3.0
GENESIS_GENERATOR_VERSION ?= 6.1.6
```

Run `make versions` to display the active lock. The derived Docker image names
normally do not need to be edited.

`GETH_VERSION` must be an official upstream `vMAJOR.MINOR.PATCH` tag. `AB_GETH_VERSION` adds a positive AB patch revision.

When upstream Geth changes, update `GETH_VERSION` and reset the AB revision to `ab.1`:

```text
v1.17.5-ab.2 -> v1.17.6-ab.1
```

When the AB patches or relevant build inputs change without an upstream version change, increment the AB revision:

```text
v1.17.6-ab.1 -> v1.17.6-ab.2
```

Never reuse an AB Geth version for different build inputs.

Lighthouse follows the same rule: `LIGHTHOUSE_VERSION` selects the upstream
source tag, and `AB_LIGHTHOUSE_VERSION` selects the patched build revision.
For example, use `v8.2.2-ab.2` after changing a patch or build input, or
`v8.2.3-ab.1` after upgrading upstream. The AB patch sets
`BASE_REWARD_FACTOR=8`; the stock Lighthouse binary is not interchangeable.

## Local builds

Building clients requires Docker Engine with Buildx. On Ubuntu with
`docker.io`, install `docker-buildx`; Docker CE uses `docker-buildx-plugin`.
Check availability with `docker buildx version`.

Validate the network files and build scripts:

```bash
make check
```

Build the selected network archive:

```bash
make network CHAIN=abcore NETWORK=testnet VERSION=v1.2.3 RELEASE_PHASE=release
```

Use `RELEASE_PHASE=candidate` for a Genesis Candidate whose bootstrap node files have not yet been populated. Normal Releases use `RELEASE_PHASE=release` and require valid consensus and execution bootstrap node lists. A checkpoint URL is validated when present but does not determine the Release mode.

Build the patched static Geth binary:

```bash
make geth
```

Every patch under `patches/go-ethereum/` must pass `git apply --check` against the pinned upstream tag. A failed check stops the build without fuzzy or partial application.

Build the patched Lighthouse binary (Rust compilation can take substantial time):

```bash
make lighthouse
```

Every patch under `patches/lighthouse/` must also pass `git apply --check`.
The binary uses the `portable,gnosis` features and the `maxperf` profile,
matching the reference build in pos-docs.

Build both exact-version runtime images:

```bash
make docker
```

`make docker` creates the exact local image tags:

```text
ghcr.io/abdaodev/ab-geth:v1.17.5-ab.1
ghcr.io/abdaodev/ab-lighthouse:v8.2.2-ab.1
```

It does not move `latest`. Remove generated files under this repository's `build/` directory with:

```bash
make clean
```

Use `make geth-docker` or `make lighthouse-docker` to build only one image.
Running `make` without a target builds the network archive, both patched
binaries, and both Docker images.

## Release assets

Every full Network Release contains one network archive for each populated
`<chain>/<network>/share` directory, plus AB Geth and AB Lighthouse binaries:

```text
abcore-testnet-v1.2.3.tar.gz
abcore-testnet-v1.2.3.tar.gz.sha256
ab-geth-v1.17.5-ab.1-linux-amd64
ab-geth-v1.17.5-ab.1-linux-amd64.sha256
ab-lighthouse-v8.2.2-ab.1-linux-amd64
ab-lighthouse-v8.2.2-ab.1-linux-amd64.sha256
```

The same Release may contain archives for multiple chains and networks. Two
Releases reuse the same client binaries when their AB versions have not changed.
Local ARM64 builds can use `GETH_PLATFORM=linux/arm64` and
`LIGHTHOUSE_PLATFORM=linux/arm64` with a builder supporting that platform.
The GitHub workflow publishes Linux AMD64 by default.

## GitHub Release workflows

### Publish Genesis participation settings

Before collecting Genesis Deposit Data, commit a zero-root
`<chain>/<network>/share/deposit-settings.json` and push the signed `rc.0` tag:

```bash
git tag -s v1.2.3-rc.0 -m "AB PoS testnet Genesis Participation v1.2.3-rc.0"
git push <github-remote> v1.2.3-rc.0
```

The workflow publishes a Pre-release containing only the following assets for
each zero-root network settings file:

```text
abcore-testnet-v1.2.3-rc.0.tar.gz
abcore-testnet-v1.2.3-rc.0.tar.gz.sha256
```

The archive contains `deposit-settings.json` and `client-versions.json`.
The `rc.0` workflow does not build or publish client binaries or images.
Genesis Validator Operators use this exact tag
with `ab-pos.sh --generate-keys --release`.

### Build a Genesis Candidate

Push a signed release-candidate tag:

```bash
git tag -s v1.2.3-rc.1 -m "AB PoS testnet Genesis Candidate v1.2.3-rc.1"
git push <github-remote> v1.2.3-rc.1
```

The workflow publishes this tag as a complete GitHub Pre-release. Candidate validation permits missing or empty `bootstrap_nodes.txt` and `bootstrap_nodes_execution.txt`. Genesis Validator Operators and Infrastructure Operators install this exact tag on their long-lived nodes, then return the execution enode and consensus ENR printed by `ab-pos.sh`.

### Build the Final Genesis Release

Add the reviewed enodes and ENRs to the two bootstrap node files without changing any Genesis or client configuration file. Commit that update, then push the matching Final tag:

```bash
git tag -s v1.2.3 -m "AB PoS testnet v1.2.3"
git push <github-remote> v1.2.3
```

When a matching `v1.2.3-rc.NUMBER` Pre-release exists, the workflow downloads it and verifies that its Genesis, client configuration, and public Genesis metadata are byte-for-byte identical. The bootstrap node lists and Checkpoint endpoints are the only files allowed to be completed between Candidate and Final. A matching Candidate is not required for an ordinary stable Release.

### Build another stable Release

Push a new signed stable tag whenever reviewed network files or bundled client versions change:

```bash
git tag -s v1.2.4 -m "AB PoS testnet v1.2.4"
git push <github-remote> v1.2.4
```

For each Candidate or stable tag, the workflow performs the following operations:

1. Validates and packages the network files.
2. Checks whether the exact AB Geth and AB Lighthouse image tags already exist.
3. Builds and pushes the exact image only when it does not exist.
4. Otherwise, pulls the exact image and extracts its client binary without recompiling or overwriting the image.
5. Produces both client binary checksums.
6. Publishes all files in a versioned GitHub Release without marking it as latest.

Every versioned Release can be tested explicitly with `ab-pos.sh --release <tag>`.
Candidate tags are Pre-releases and are never eligible for Latest or either
client's `latest` image tag. Building a versioned Release does not move these pointers.

### Publish and promote a Release

After testing the versioned Release, edit it on GitHub, select **Set as the latest release**, and save it. The Release event runs the promotion workflow automatically. Publishing a previous Draft Release also triggers the workflow when that Release becomes Latest.

To retry or perform the same promotion explicitly, open GitHub Actions, select **Promote AB PoS release**, choose **Run workflow**, and enter the Network Release tag.

The manual workflow:

1. Checks that every Network archive has a checksum asset.
2. Checks that every AB client binary has a checksum asset and there is one version per client.
3. Verifies that the immutable GHCR images for both client versions exist.
4. Marks the selected versioned Release as the latest GitHub Release.
5. Points both AB client `latest` image tags to the exact images selected by that Network Release.

The selected Release controls `latest`; the workflow does not choose a different image merely because its version number is higher. Release jobs share one concurrency group so a tagged build and a promotion cannot run simultaneously.

## Image tag immutability

When an exact AB client image tag already exists, the workflow verifies its version
label and reuses it instead of overwriting it. If upstream source, patches, or
build inputs change, update `AB_GETH_VERSION` or `AB_LIGHTHOUSE_VERSION`
before publishing.

Registry administrators can still mutate tags manually, so production verification may additionally pin an image digest.

## Manual image publication

The same guarded publication path is available locally after GHCR authentication:

```bash
make push-docker
```

It prepares or reuses both exact images and points their `latest` tags to
`AB_GETH_VERSION` and `AB_LIGHTHOUSE_VERSION`. It does not create, publish,
or promote a GitHub Release.
