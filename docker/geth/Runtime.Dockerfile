FROM alpine:3.22

ARG AB_GETH_VERSION=development
RUN apk add --no-cache ca-certificates
COPY geth /usr/local/bin/geth

LABEL org.opencontainers.image.title="AB Geth" \
      org.opencontainers.image.description="AB PoS patched go-ethereum execution client" \
      org.opencontainers.image.source="https://github.com/abdaodev/ab-pos-deploy" \
      org.opencontainers.image.version="${AB_GETH_VERSION}"

EXPOSE 8545 8546 8551 30303 30303/udp
ENTRYPOINT ["geth"]
