# overleaf-noavx

Self-hosted [Overleaf](https://www.overleaf.com) – genauer die
[Extended Community Edition (CEP)](https://github.com/yu-i-i/overleaf-cep) – auf Hardware
**ohne AVX** (typisch: NAS und Mini-PCs mit Celeron, Pentium Silver oder Atom).

Overleaf 6.x verlangt MongoDB 8.0, und die offiziellen MongoDB-Builds starten ohne AVX nicht.
Dieses Repository enthält alles, um das zu umgehen:

| Verzeichnis | Inhalt |
|---|---|
| [`mongodb-noavx/`](mongodb-noavx) | Build von MongoDB 8.0 ohne AVX als Docker-Image |
| [`overleaf/`](overleaf) | Docker-Compose-Setup für Overleaf CEP 6.x mit vollständigem TeX Live und automatischem Backup |
| [`docs/migration-5.5-to-6.3.md`](docs/migration-5.5-to-6.3.md) | Upgrade von Overleaf 5.5 + MongoDB 7 auf 6.3 + MongoDB 8 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Fehlerbilder und Lösungen |

## Schnellstart

**1. Prüfen, ob du das brauchst** (auf dem Zielsystem):

```bash
grep -o -w avx /proc/cpuinfo | head -1
```

Ausgabe `avx` → offizielles `mongo:8.0` verwenden und direkt bei Schritt 3 weitermachen
(`MONGO_IMAGE=mongo:8.0` in `overleaf/.env`).

**2. MongoDB-Image ohne AVX besorgen**

Fertiges Image auf Docker Hub – für CPUs mit SSE4.2/POPCNT, aber ohne AVX (`nehalem`):

```bash
docker pull devferris/mongodb-no-avx:8.0.17-nehalem
docker run --rm devferris/mongodb-no-avx:8.0.17-nehalem --version     # Smoke-Test auf dem Zielsystem
```

Das ist der Standard in `overleaf/docker-compose.yml`. Startet es mit `Illegal instruction`,
oder willst du selbst bauen (`core2`, eigene UID, neuere Version), dann auf einem kräftigen
x86_64-Rechner – dauert Stunden:

```bash
cd mongodb-noavx
CPU_ARCH=nehalem JOBS=2 ./build.sh --save
# Ergebnis aufs NAS kopieren und dort: gunzip -c <datei>.tar.gz | docker load
```

Details: [`mongodb-noavx/README.md`](mongodb-noavx/README.md)

**3. Overleaf aufsetzen** – auf dem NAS:

```bash
cd overleaf
cp .env.example .env && cp overleaf.env.example overleaf.env
# OVERLEAF_SITE_URL, Secret (openssl rand -base64 32) usw. eintragen
docker compose pull              # TeX Live ~5 GB
docker compose up -d             # erster Start kopiert TeX Live ins Volume, einige Minuten
```

Danach `http://<host>:8088/launchpad` für den ersten Admin.
Details: [`overleaf/README.md`](overleaf/README.md)

**Bestehende 5.5-Installation?** → [`docs/migration-5.5-to-6.3.md`](docs/migration-5.5-to-6.3.md)

## Referenz-Setup

| Komponente | Version |
|---|---|
| Overleaf | `overleafcep/sharelatex:6.3.0-ext-v5.1` |
| MongoDB | [`devferris/mongodb-no-avx:8.0.17-nehalem`](https://hub.docker.com/r/devferris/mongodb-no-avx) – 8.0.17, `-march=nehalem`, Build über [Axcient/mongod-avx](https://github.com/Axcient/mongod-avx) `v8.0.17` |
| Redis | 7.4 |
| TeX Live | `texlive/texlive:latest-full`, per Volume eingebunden |
| Backup | `offen/docker-volume-backup:v2`, MongoDB per `mongodump --oplog` |
| Build-Host | Intel-Mac, Docker Desktop, 12 GB VM |

## Hinweise

- Der MongoDB-Build ist inoffiziell und von MongoDB weder getestet noch unterstützt.
  Regelmäßige Backups sind Pflicht.
- Overleaf Community Edition ist für Umgebungen mit vertrauenswürdigen Nutzern gedacht:
  LaTeX wird ohne Sandbox direkt im Overleaf-Container kompiliert.
- MongoDB steht unter der SSPL, Overleaf unter der AGPLv3.

## Danksagung

- [Axcient/mongod-avx](https://github.com/Axcient/mongod-avx) – Patches und Bazel-Konfiguration für MongoDB 8.0 ohne AVX
- [fenio/mongodb-no-avx](https://github.com/fenio/mongodb-no-avx) – MongoDB 7.0 ohne AVX, Vorlage für das Laufzeit-Image
- [yu-i-i/overleaf-cep](https://github.com/yu-i-i/overleaf-cep) – Overleaf Extended Community Edition
