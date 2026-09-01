SHELL := /bin/bash

CHAIN := abpos
NETWORKS := testnet
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || date +%Y%m%d%H%M%S)

.PHONY: all $(NETWORKS) build clean check

all: $(NETWORKS)

$(NETWORKS):
	@./build.sh "$(VERSION)" "$(CHAIN)" "$@"

build:
	@[ -n "$(NETWORK)" ] || { echo "NETWORK is required" >&2; exit 1; }
	@./build.sh "$(VERSION)" "$(CHAIN)" "$(NETWORK)"

check:
	@for network in $(NETWORKS); do \
		./build.sh --check "$(CHAIN)" "$$network"; \
	done

clean:
	rm -rf -- build
