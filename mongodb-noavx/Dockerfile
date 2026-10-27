# syntax=docker/dockerfile:1
#
# Runtime image for a mongod built without AVX (MongoDB 8.0.x).
# Expects the finished binary at ./bin/mongod (produced by build.sh).
#
# Deliberately modelled on ghcr.io/fenio/mongodb-no-avx:
#   ENTRYPOINT mongod, CMD --bind_ip_all, user "mongodb", /data/db as volume
# -> An existing compose configuration (command: "--replSet rs0 ...") works unchanged.

FROM ubuntu:noble

ARG MONGO_VERSION=8.0.17
ARG CPU_ARCH=nehalem
# UID/GID must match the owner of an existing mongo_data volume
# (check with:  docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28)
ARG MONGO_UID=999
ARG MONGO_GID=999

LABEL org.opencontainers.image.title="mongodb-no-avx" \
      org.opencontainers.image.description="MongoDB ${MONGO_VERSION} without AVX (-march=${CPU_ARCH}), built with Axcient/mongod-avx" \
      org.opencontainers.image.version="${MONGO_VERSION}" \
      org.opencontainers.image.licenses="SSPL-1.0" \
      org.opencontainers.image.source="https://github.com/dev-ferris/overleaf-noavx" \
      org.opencontainers.image.url="https://hub.docker.com/r/devferris/mongodb-no-avx" \
      org.opencontainers.image.documentation="https://github.com/dev-ferris/overleaf-noavx/tree/main/mongodb-noavx"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime dependencies of a mongod built on Ubuntu Noble
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        libatomic1 \
        libcurl4t64 \
        libssl3t64 \
        liblzma5 \
        tzdata \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd -r -g "${MONGO_GID}" mongodb \
 && useradd  -r -u "${MONGO_UID}" -g mongodb -M -d /data/db -s /usr/sbin/nologin mongodb \
 && mkdir -p /data/db /data/configdb \
 && chown -R mongodb:mongodb /data/db /data/configdb

COPY --chmod=0755 bin/mongod /usr/local/bin/mongod

# Build-time check: all libraries resolvable and binary starts
RUN if ldd /usr/local/bin/mongod | grep -q "not found"; then \
        echo "ERROR: missing libraries:"; ldd /usr/local/bin/mongod | grep "not found"; exit 1; \
    fi \
 && /usr/local/bin/mongod --version

# tcmalloc-google (MongoDB 8's allocator) does not cope well with glibc rseq;
# without this variable mongod warns at startup about significant performance loss.
# The official mongo:8.0 image sets it as well.
ENV GLIBC_TUNABLES=glibc.pthread.rseq=0

VOLUME ["/data/db", "/data/configdb"]
EXPOSE 27017
USER mongodb

ENTRYPOINT ["/usr/local/bin/mongod"]
CMD ["--bind_ip_all"]
