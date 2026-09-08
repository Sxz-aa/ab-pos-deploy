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

# Client version lock.
# When a new upstream version is available, test it on the target network with
# an environment-variable override, then update the version here.
PRYSM_VERSION ?= v7.1.8
LIGHTHOUSE_VERSION ?= v8.2.2
DEPOSIT_CLI_VERSION ?= v1.3.0
GENESIS_GENERATOR_VERSION ?= 6.1.6

# Derived image names. Normally these do not need to be edited.
PRYSM_BEACON_IMAGE ?= offchainlabs/prysm-beacon-chain:$(PRYSM_VERSION)
PRYSM_VALIDATOR_IMAGE ?= offchainlabs/prysm-validator:$(PRYSM_VERSION)
LIGHTHOUSE_IMAGE ?= sigp/lighthouse:$(LIGHTHOUSE_VERSION)
DEPOSIT_CLI_IMAGE ?= ghcr.io/ethstaker/ethstaker-deposit-cli:$(DEPOSIT_CLI_VERSION)
GENESIS_GENERATOR_IMAGE ?= ethpandaops/ethereum-genesis-generator:$(GENESIS_GENERATOR_VERSION)

GETH_ARCH := $(word 2,$(subst /, ,$(GETH_PLATFORM)))
GETH_ARTIFACT := $(BUILD_DIR)/ab-geth-$(AB_GETH_VERSION)-linux-$(GETH_ARCH)
DEVP2P_ARTIFACT := $(BUILD_DIR)/devp2p-$(GETH_VERSION)-linux-$(GETH_ARCH)
GETH_PATCHES := $(wildcard patches/go-ethereum/*.patch)
CLIENT_VERSIONS_FILE := $(BUILD_DIR)/client-versions.json

export ROOT_DIR BUILD_DIR CHAIN NETWORK VERSION RELEASE_PHASE
export GETH_REPOSITORY GETH_VERSION AB_GETH_VERSION GETH_IMAGE GETH_PLATFORM
export PRYSM_VERSION PRYSM_BEACON_IMAGE PRYSM_VALIDATOR_IMAGE
export LIGHTHOUSE_VERSION LIGHTHOUSE_IMAGE
export DEPOSIT_CLI_VERSION DEPOSIT_CLI_IMAGE
export GENESIS_GENERATOR_VERSION GENESIS_GENERATOR_IMAGE CLIENT_VERSIONS_FILE

.PHONY: all network testnet mainnet check versions client-versions geth geth-version genesis-generator-image devp2p verify-bootnodes docker push-docker clean

all: network geth docker

network: check client-versions
	./build.sh "$(VERSION)" "$(CHAIN)" "$(NETWORK)" "$(RELEASE_PHASE)"

testnet:
	$(MAKE) network CHAIN="$(CHAIN)" NETWORK=testnet VERSION="$(VERSION)" RELEASE_PHASE="$(RELEASE_PHASE)"

mainnet:
	$(MAKE) network CHAIN="$(CHAIN)" NETWORK=mainnet VERSION="$(VERSION)" RELEASE_PHASE="$(RELEASE_PHASE)"

check: client-versions
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

genesis-generator-image:
	@printf '%s\n' "$(GENESIS_GENERATOR_IMAGE)"

client-versions:
	@mkdir -p "$(BUILD_DIR)"
	@jq -n '{geth: {upstream_version: env.GETH_VERSION, ab_version: env.AB_GETH_VERSION}, prysm: {version: env.PRYSM_VERSION, beacon_image: env.PRYSM_BEACON_IMAGE, validator_image: env.PRYSM_VALIDATOR_IMAGE}, lighthouse: {version: env.LIGHTHOUSE_VERSION, image: env.LIGHTHOUSE_IMAGE}, deposit_cli: {version: env.DEPOSIT_CLI_VERSION, image: env.DEPOSIT_CLI_IMAGE}}' >"$(CLIENT_VERSIONS_FILE).tmp"
	@mv -f "$(CLIENT_VERSIONS_FILE).tmp" "$(CLIENT_VERSIONS_FILE)"

versions:
	@printf '%-24s %s\n' \
		'AB Geth' '$(AB_GETH_VERSION)' \
		'Geth upstream' '$(GETH_VERSION)' \
		'Prysm' '$(PRYSM_VERSION)' \
		'Lighthouse' '$(LIGHTHOUSE_VERSION)' \
		'Deposit CLI' '$(DEPOSIT_CLI_VERSION)' \
		'Genesis Generator' '$(GENESIS_GENERATOR_VERSION)'

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
