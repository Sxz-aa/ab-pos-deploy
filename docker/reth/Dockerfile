# syntax=docker/dockerfile:1

FROM rust:1.95.0-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang \
    cmake \
    libclang-dev \
    pkg-config \
    libssl-dev \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

ARG TARGETARCH

WORKDIR /reth
COPY . .

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,id=reth-target-bookworm-${TARGETARCH},target=/reth/target \
    cargo build \
        --release \
        --locked \
        -p abcore-withdrawals \
    && install -m 0755 \
        target/release/abcore-withdrawals \
        /usr/local/bin/reth

FROM scratch AS binary

COPY --from=builder /usr/local/bin/reth /reth
