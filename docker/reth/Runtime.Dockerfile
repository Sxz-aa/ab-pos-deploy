FROM debian:bookworm-slim

ARG AB_RETH_VERSION=development

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY reth /usr/local/bin/reth

LABEL org.opencontainers.image.title="AB Reth" \
      org.opencontainers.image.description="AB PoS patched Reth execution client" \
      org.opencontainers.image.source="https://github.com/abdaodev/ab-pos-deploy" \
      org.opencontainers.image.version="${AB_RETH_VERSION}"

EXPOSE 8545 8546 8551 30303 30303/udp

ENTRYPOINT ["reth"]
