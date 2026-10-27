# overleaf-noavx

Self-hosted [Overleaf](https://www.overleaf.com) – more precisely the
[Extended Community Edition (CEP)](https://github.com/yu-i-i/overleaf-cep) – on hardware
**without AVX** (typically NAS boxes and mini PCs with Celeron, Pentium Silver or Atom CPUs).

Overleaf 6.x requires MongoDB 8.0, and the official MongoDB builds do not start without AVX.
This repository contains everything needed to work around that:

| Directory | Contents |
|---|---|
| [`mongodb-noavx/`](mongodb-noavx) | Build of MongoDB 8.0 without AVX as a Docker image |
| [`overleaf/`](overleaf) | Docker Compose setup for Overleaf CEP 6.x with a full TeX Live |
| [`docs/migration-5.5-to-6.3.md`](docs/migration-5.5-to-6.3.md) | Upgrade from Overleaf 5.5 + MongoDB 7 to 6.3 + MongoDB 8 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Common errors and fixes |

## Quick start

**1. Check whether you need this** (on the target machine):

```bash
grep -o -w avx /proc/cpuinfo | head -1
```

Output `avx` → use the official `mongo:8.0` image and continue with step 3
(`MONGO_IMAGE=mongo:8.0` in `overleaf/.env`).

**2. Get the MongoDB image without AVX**

Prebuilt image on Docker Hub (identical copy at `ghcr.io/dev-ferris/mongodb-no-avx`) –
for CPUs with SSE4.2/POPCNT but without AVX (`nehalem`):

```bash
docker pull devferris/mongodb-no-avx:8.0.17-nehalem
docker run --rm devferris/mongodb-no-avx:8.0.17-nehalem --version     # smoke test on the target machine
```

This is the default in `overleaf/docker-compose.yml`. If it fails with `Illegal instruction`,
or if you want to build it yourself (`core2`, different UID, newer version), do so on a
powerful x86_64 machine – it takes hours:

```bash
cd mongodb-noavx
CPU_ARCH=nehalem JOBS=2 ./build.sh --save
# copy the result to the target host and run there: gunzip -c <file>.tar.gz | docker load
```

Details: [`mongodb-noavx/README.md`](mongodb-noavx/README.md)

**3. Set up Overleaf** – on the target host:

```bash
cd overleaf
cp .env.example .env && cp overleaf.env.example overleaf.env
# fill in OVERLEAF_SITE_URL, secret (openssl rand -base64 32) etc.
docker compose pull              # TeX Live image: several GB
docker compose up -d             # first start copies TeX Live into a volume, a few minutes
```

Then open `http://<host>:8088/launchpad` to create the first admin.
Details: [`overleaf/README.md`](overleaf/README.md)

**Existing 5.5 installation?** → [`docs/migration-5.5-to-6.3.md`](docs/migration-5.5-to-6.3.md)

## Reference setup

| Component | Version |
|---|---|
| Overleaf | `overleafcep/sharelatex:6.3.0-ext-v5.1` |
| MongoDB | [`devferris/mongodb-no-avx:8.0.17-nehalem`](https://hub.docker.com/r/devferris/mongodb-no-avx) – 8.0.17, `-march=nehalem`, built via [Axcient/mongod-avx](https://github.com/Axcient/mongod-avx) `v8.0.17` |
| Redis | 7.4 |
| TeX Live | `texlive/texlive:latest`, mounted as a volume |
| Build host | Intel Mac, Docker Desktop, 12 GB VM |

## Notes

- The MongoDB build is unofficial and neither tested nor supported by MongoDB.
  Regular backups are mandatory.
- Overleaf Community Edition is intended for environments with trusted users:
  LaTeX is compiled without a sandbox directly in the Overleaf container.
- MongoDB is licensed under the SSPL, Overleaf under the AGPLv3.

## Credits

- [Axcient/mongod-avx](https://github.com/Axcient/mongod-avx) – patches and Bazel configuration for MongoDB 8.0 without AVX
- [fenio/mongodb-no-avx](https://github.com/fenio/mongodb-no-avx) – MongoDB 7.0 without AVX, template for the runtime image
- [yu-i-i/overleaf-cep](https://github.com/yu-i-i/overleaf-cep) – Overleaf Extended Community Edition
