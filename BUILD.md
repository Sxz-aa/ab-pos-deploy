# AB PoS Build and Release Guide

This document is for repository maintainers who build Network Release assets and the patched AB Geth execution client.

## Versioning

The repository uses one Network Release tag, such as `v1.2.3`. The tagged source tree pins the execution-client inputs in the `Makefile`:

```make
GETH_VERSION ?= v1.17.5
AB_GETH_VERSION ?= $(GETH_VERSION)-ab.1
```

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

## Local builds

Validate the network files and build scripts:

```bash
make check
```

Build the selected network archive:

```bash
make network VERSION=v1.2.3 RELEASE_PHASE=genesis
```

Use `RELEASE_PHASE=post-genesis` after a trusted checkpoint provider has been published. That mode requires a valid `checkpoint_sync_urls.txt`.

Build the patched static Geth binary:

```bash
make geth
```

Every patch under `patches/go-ethereum/` must pass `git apply --check` against the pinned upstream tag. A failed check stops the build without fuzzy or partial application.

Build the exact-version runtime image and Docker archive:

```bash
make docker
```

`make docker` creates only the exact local image tag:

```text
ghcr.io/abdaodev/ab-geth:v1.17.5-ab.1
```

It does not move `latest`. Remove generated files under this repository's `build/` directory with:

```bash
make clean
```

Running `make` without a target builds the network archive, patched binary, and Docker archive.

## Release assets

Every Network Release is self-contained and contains:

```text
abpos-testnet-v1.2.3.tar.gz
abpos-testnet-v1.2.3.tar.gz.sha256
ab-geth-v1.17.5-ab.1-linux-amd64
ab-geth-v1.17.5-ab.1-linux-amd64.sha256
```

Two Network Releases may contain the same AB Geth binary when the execution-client version has not changed.

## GitHub Release workflows

### Build a versioned Release

Push a signed Network Release tag to GitHub:

```bash
git tag -s v1.2.3 -m "AB PoS testnet v1.2.3"
git push <github-remote> v1.2.3
```

The workflow performs the following operations:

1. Validates and packages the network files.
2. Checks whether `ghcr.io/abdaodev/ab-geth:<AB_GETH_VERSION>` already exists.
3. Builds and pushes the exact image only when it does not exist.
4. Otherwise, pulls the exact image and extracts `/usr/local/bin/geth` without recompiling or overwriting the image.
5. Produces the AB Geth binary checksum.
6. Publishes all files in a versioned GitHub Release without marking it as latest.

The versioned Release can be tested explicitly with `ab-pos.sh --release <tag>`. This workflow does not change the latest GitHub Release or the AB Geth `latest` image tag.

### Publish and promote a Release

After testing the versioned Release, open GitHub Actions, select **Promote AB PoS release**, choose **Run workflow**, and enter the Network Release tag.

The manual workflow:

1. Verifies that the Release contains one matching Network archive and checksum.
2. Verifies that every AB Geth binary has a checksum and that all binaries use one AB Geth version.
3. Verifies that the immutable GHCR image for that AB Geth version exists.
4. Marks the selected versioned Release as the latest GitHub Release.
5. Points the AB Geth `latest` image tag to the exact immutable image selected by that Network Release.

The selected Release controls `latest`; the workflow does not choose a different image merely because its version number is higher. Release jobs share one concurrency group so a tagged build and a promotion cannot run simultaneously.

## Image immutability

New images contain a build fingerprint derived from the pinned upstream version, target platform, patches, Dockerfiles, and relevant build scripts. When an exact image tag already exists:

- A matching fingerprint permits reuse.
- A different fingerprint fails the Release and requires a new AB revision.
- An older image without a fingerprint may be reused only when its exact version label matches; the workflow prints a compatibility warning.

The workflow protects exact tags from accidental replacement. Registry administrators can still mutate tags manually, so production verification may additionally pin an image digest.

## Manual image publication

The same guarded publication path is available locally after GHCR authentication:

```bash
make push-docker
```

It prepares or reuses the exact image and points `latest` to `AB_GETH_VERSION`. It does not create, publish, or promote a GitHub Release.
