FROM ubuntu:22.04
ARG AB_LIGHTHOUSE_VERSION=development
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY lighthouse /usr/local/bin/lighthouse
LABEL org.opencontainers.image.title="AB Lighthouse" \
      org.opencontainers.image.description="AB PoS patched Lighthouse consensus client" \
      org.opencontainers.image.source="https://github.com/abdaodev/ab-pos-deploy" \
      org.opencontainers.image.version="${AB_LIGHTHOUSE_VERSION}"
# Keep the upstream command interface: lighthouse bn / vc / account.
CMD ["lighthouse", "--help"]
