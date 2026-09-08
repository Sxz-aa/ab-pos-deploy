# syntax=docker/dockerfile:1
# Match the upstream v8.2.2 build toolchain and use portable CPU features.
FROM rust:1.88.0-bookworm AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake libclang-dev pkg-config libssl-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ARG TARGETARCH
WORKDIR /lighthouse
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,id=lighthouse-target-bookworm-${TARGETARCH},target=/lighthouse/target \
    cargo build --bin lighthouse --features portable,gnosis --profile maxperf --locked \
    && install -m 0755 target/maxperf/lighthouse /usr/local/bin/lighthouse

FROM scratch AS binary
COPY --from=builder /usr/local/bin/lighthouse /lighthouse
