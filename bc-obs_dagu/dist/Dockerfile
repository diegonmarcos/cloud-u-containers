FROM ghcr.io/dagu-org/dagu:1.30.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*
