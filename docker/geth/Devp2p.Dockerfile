# syntax=docker/dockerfile:1

FROM golang:1.26-alpine AS builder

RUN apk add --no-cache gcc git linux-headers musl-dev
WORKDIR /go-ethereum
COPY . .
RUN go run build/ci.go install -static ./cmd/devp2p

FROM scratch AS binary
COPY --from=builder /go-ethereum/build/bin/devp2p /devp2p

FROM alpine:3.22 AS runtime

RUN apk add --no-cache ca-certificates
COPY --from=builder /go-ethereum/build/bin/devp2p /usr/local/bin/devp2p
ENTRYPOINT ["devp2p"]
