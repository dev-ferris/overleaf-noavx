# syntax=docker/dockerfile:1
#
# Laufzeit-Image für ein ohne AVX gebautes mongod (MongoDB 8.0.x).
# Erwartet das fertige Binary unter ./bin/mongod (erzeugt von build.sh).
#
# Aufbau bewusst analog zu ghcr.io/fenio/mongodb-no-avx:
#   ENTRYPOINT mongod, CMD --bind_ip_all, User "mongodb", /data/db als Volume
# -> Die bestehende compose-Konfiguration (command: "--replSet rs0 ...") passt unverändert.

FROM ubuntu:noble

ARG MONGO_VERSION=8.0.17
ARG CPU_ARCH=nehalem
# UID/GID müssen zum Besitzer des bestehenden mongo_data-Volumes passen
# (prüfen mit:  docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28)
ARG MONGO_UID=999
ARG MONGO_GID=999

LABEL org.opencontainers.image.title="mongodb-no-avx" \
      org.opencontainers.image.description="MongoDB ${MONGO_VERSION} ohne AVX (-march=${CPU_ARCH}), gebaut mit Axcient/mongod-avx" \
      org.opencontainers.image.version="${MONGO_VERSION}" \
      org.opencontainers.image.licenses="SSPL-1.0" \
      org.opencontainers.image.source="https://github.com/dev-ferris/overleaf-noavx" \
      org.opencontainers.image.url="https://hub.docker.com/r/devferris/mongodb-no-avx" \
      org.opencontainers.image.documentation="https://github.com/dev-ferris/overleaf-noavx/tree/main/mongodb-noavx"

ENV DEBIAN_FRONTEND=noninteractive

# Laufzeitabhängigkeiten des auf Ubuntu Noble gebauten mongod
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

# Build-Zeit-Prüfung: alle Bibliotheken auflösbar und Binary startfähig
RUN if ldd /usr/local/bin/mongod | grep -q "not found"; then \
        echo "FEHLER: fehlende Bibliotheken:"; ldd /usr/local/bin/mongod | grep "not found"; exit 1; \
    fi \
 && /usr/local/bin/mongod --version

# tcmalloc-google (Allokator von MongoDB 8) kommt mit glibc-rseq nicht zurecht;
# ohne diese Variable warnt mongod beim Start vor deutlichen Performance-Einbußen.
# Das offizielle mongo:8.0-Image setzt sie ebenfalls.
ENV GLIBC_TUNABLES=glibc.pthread.rseq=0

VOLUME ["/data/db", "/data/configdb"]
EXPOSE 27017
USER mongodb

ENTRYPOINT ["/usr/local/bin/mongod"]
CMD ["--bind_ip_all"]
