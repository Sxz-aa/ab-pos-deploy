# syntax=docker/dockerfile:1

FROM golang:1.26-alpine AS builder

RUN apk add --no-cache gcc git linux-headers musl-dev
WORKDIR /go-ethereum
COPY . .
RUN go run build/ci.go install -static ./cmd/geth

FROM scratch AS binary
COPY --from=builder /go-ethereum/build/bin/geth /geth

FROM alpine:3.22 AS runtime

ARG AB_GETH_VERSION=development
RUN apk add --no-cache ca-certificates
COPY --from=builder /go-ethereum/build/bin/geth /usr/local/bin/geth

LABEL org.opencontainers.image.title="AB Geth" \
      org.opencontainers.image.description="AB PoS patched go-ethereum execution client" \
      org.opencontainers.image.source="https://github.com/abdaodev/ab-pos-deploy" \
      org.opencontainers.image.version="${AB_GETH_VERSION}"

EXPOSE 8545 8546 8551 30303 30303/udp
ENTRYPOINT ["geth"]
