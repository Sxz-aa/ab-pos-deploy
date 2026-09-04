SHELL := /usr/bin/env bash

ROOT_DIR := $(CURDIR)
BUILD_DIR := $(ROOT_DIR)/build
CHAIN ?= abcore
NETWORK ?= testnet
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || printf 'dev')
RELEASE_PHASE ?= release

GETH_REPOSITORY ?= https://github.com/ethereum/go-ethereum.git
GETH_VERSION ?= v1.17.5
AB_GETH_VERSION ?= $(GETH_VERSION)-ab.1
GETH_IMAGE ?= ghcr.io/abdaodev/ab-geth
GETH_PLATFORM ?= linux/amd64
GETH_ARCH := $(word 2,$(subst /, ,$(GETH_PLATFORM)))
GETH_ARTIFACT := $(BUILD_DIR)/ab-geth-$(AB_GETH_VERSION)-linux-$(GETH_ARCH)
DEVP2P_ARTIFACT := $(BUILD_DIR)/devp2p-$(GETH_VERSION)-linux-$(GETH_ARCH)
GETH_PATCHES := $(wildcard patches/go-ethereum/*.patch)

export ROOT_DIR BUILD_DIR CHAIN NETWORK VERSION RELEASE_PHASE
export GETH_REPOSITORY GETH_VERSION AB_GETH_VERSION GETH_IMAGE GETH_PLATFORM

.PHONY: all network testnet mainnet check geth geth-version devp2p verify-bootnodes docker push-docker clean

all: network geth docker

network: check
	./build.sh "$(VERSION)" "$(CHAIN)" "$(NETWORK)" "$(RELEASE_PHASE)"

testnet:
	$(MAKE) network CHAIN="$(CHAIN)" NETWORK=testnet VERSION="$(VERSION)" RELEASE_PHASE="$(RELEASE_PHASE)"

mainnet:
	$(MAKE) network CHAIN="$(CHAIN)" NETWORK=mainnet VERSION="$(VERSION)" RELEASE_PHASE="$(RELEASE_PHASE)"

check:
	./build.sh --check "$(CHAIN)" "$(NETWORK)" "$(RELEASE_PHASE)"
	@test -x ab-pos.sh || { echo "ERROR: ab-pos.sh is missing or not executable." >&2; exit 1; }
	@bash -n ab-pos.sh
	@test -x scripts/prepare-geth-source.sh || { echo "ERROR: scripts/prepare-geth-source.sh is missing or not executable." >&2; exit 1; }
	@test -x scripts/build-geth.sh || { echo "ERROR: scripts/build-geth.sh is missing or not executable." >&2; exit 1; }
	@test -x scripts/build-geth-docker.sh || { echo "ERROR: scripts/build-geth-docker.sh is missing or not executable." >&2; exit 1; }
	@test -x scripts/build-devp2p.sh || { echo "ERROR: scripts/build-devp2p.sh is missing or not executable." >&2; exit 1; }
	@test -x scripts/verify-bootnodes.sh || { echo "ERROR: scripts/verify-bootnodes.sh is missing or not executable." >&2; exit 1; }
	@bash -n scripts/build-devp2p.sh
	@bash -n scripts/verify-bootnodes.sh
	@test -x scripts/geth-build-fingerprint.sh || { echo "ERROR: scripts/geth-build-fingerprint.sh is missing or not executable." >&2; exit 1; }
	@test -x scripts/export-geth-image.sh || { echo "ERROR: scripts/export-geth-image.sh is missing or not executable." >&2; exit 1; }
	@test -x scripts/prepare-geth-release.sh || { echo "ERROR: scripts/prepare-geth-release.sh is missing or not executable." >&2; exit 1; }
	@test -x scripts/update-geth-latest.sh || { echo "ERROR: scripts/update-geth-latest.sh is missing or not executable." >&2; exit 1; }
	@test -x genesis/generate-abpos-genesis.sh || { echo "ERROR: genesis/generate-abpos-genesis.sh is missing or not executable." >&2; exit 1; }
	@bash -n genesis/generate-abpos-genesis.sh
	@test -f docker/geth/Dockerfile || { echo "ERROR: docker/geth/Dockerfile is missing." >&2; exit 1; }
	@test -f docker/geth/Devp2p.Dockerfile || { echo "ERROR: docker/geth/Devp2p.Dockerfile is missing." >&2; exit 1; }
	@compgen -G 'patches/go-ethereum/*.patch' >/dev/null || { echo "ERROR: no Geth patches found under patches/go-ethereum/." >&2; exit 1; }

geth: $(GETH_ARTIFACT)

$(GETH_ARTIFACT): scripts/prepare-geth-source.sh scripts/build-geth.sh scripts/geth-build-fingerprint.sh docker/geth/Dockerfile docker/geth/Runtime.Dockerfile $(GETH_PATCHES)
	./scripts/build-geth.sh

geth-version:
	@printf '%s\n' "$(AB_GETH_VERSION)"

devp2p: $(DEVP2P_ARTIFACT)

$(DEVP2P_ARTIFACT): scripts/prepare-geth-source.sh scripts/build-devp2p.sh docker/geth/Devp2p.Dockerfile $(GETH_PATCHES)
	./scripts/build-devp2p.sh

verify-bootnodes: check devp2p
	DEVP2P_BIN="$(DEVP2P_ARTIFACT)" ./scripts/verify-bootnodes.sh "$(CHAIN)" "$(NETWORK)"

docker: geth docker/geth/Runtime.Dockerfile scripts/build-geth-docker.sh
	./scripts/build-geth-docker.sh

push-docker:
	./scripts/prepare-geth-release.sh
	./scripts/update-geth-latest.sh

clean:
	@case "$(BUILD_DIR)" in "$(ROOT_DIR)/build") ;; *) echo "ERROR: refusing to clean unexpected path: $(BUILD_DIR)" >&2; exit 1;; esac
	rm -rf -- "$(BUILD_DIR)"
