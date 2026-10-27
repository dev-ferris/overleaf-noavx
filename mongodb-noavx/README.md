# MongoDB 8.0 without AVX

Overleaf 6.x requires MongoDB 8.0. The official MongoDB binaries since 5.0 need a CPU with
AVX – many NAS and mini-PC CPUs (Celeron J4105/J4125, Pentium Silver, Atom) lack it and abort
at startup with `Illegal instruction`.

This directory builds MongoDB 8.0.17 without the AVX requirement as a Docker image. The actual
work (patches against AVX in mozjs and Bazel, `-march=nehalem`/`core2`) comes from
[Axcient/mongod-avx](https://github.com/Axcient/mongod-avx); `build.sh` turns it into a
resumable build and a slim runtime image.

| File | Purpose |
|---|---|
| `build.sh` | Compiles `mongod` (or takes an existing one) and builds the runtime image |
| `Dockerfile` | Runtime image: Ubuntu Noble, entrypoint `mongod`, user `mongodb`, `/data/db` |
| `DOCKERHUB.md` | Description for the Docker Hub page |

## Prebuilt image

If you don't want to build it yourself: built with this directory, identical in two registries:

| Registry | Image |
|---|---|
| Docker Hub | [`devferris/mongodb-no-avx`](https://hub.docker.com/r/devferris/mongodb-no-avx) |
| GitHub Container Registry | `ghcr.io/dev-ferris/mongodb-no-avx` (additionally tagged `latest`) |

The GHCR copy is created by the workflow
[`.github/workflows/mirror-mongodb-image.yml`](../.github/workflows/mirror-mongodb-image.yml)
(trigger it manually under *Actions*, e.g. after a new build).

The Docker Hub description comes from [`DOCKERHUB.md`](DOCKERHUB.md) and is pushed on every
change by the workflow
[`.github/workflows/dockerhub-description.yml`](../.github/workflows/dockerhub-description.yml).
It needs the repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (personal access
token with scope *Read, Write, Delete*).

| Tag | MongoDB | `CPU_ARCH` | `mongodb` UID/GID |
|---|---|---|---|
| `8.0.17-nehalem` | 8.0.17 | `nehalem` (SSE4.2 + POPCNT, no AVX) | 999/999 |

```bash
docker pull devferris/mongodb-no-avx:8.0.17-nehalem
docker run --rm devferris/mongodb-no-avx:8.0.17-nehalem --version
```

Building it yourself is needed for CPUs without SSE4.2 (`core2`), for a different UID
(existing volume with another owner) or for a newer MongoDB version.

The image behaves like [`ghcr.io/fenio/mongodb-no-avx`](https://github.com/fenio/mongodb-no-avx)
(MongoDB 7.0 without AVX), so it is a drop-in replacement: `command: "--replSet rs0 ..."` stays the same.

---

## 1. Determine the target CPU (on the target machine)

```bash
grep -o -w -E 'avx|sse4_2|popcnt' /proc/cpuinfo | sort -u
```

| Output | Meaning |
|---|---|
| contains `avx` | No custom build needed – use the official `mongo:8.0` |
| `sse4_2` + `popcnt`, no `avx` | `CPU_ARCH=nehalem` (default) |
| no `sse4_2` | `CPU_ARCH=core2` |

If you want to reuse an existing MongoDB volume, also check the UID in the old image:

```bash
docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28
```

and pass it as `MONGO_UID`/`MONGO_GID` (default: 999).

## 2. Build (on a powerful x86_64 machine, not on the NAS)

Requirements: Docker, x86_64 (Linux or Intel Mac with Docker Desktop), bash, git.

```bash
cd mongodb-noavx
CPU_ARCH=nehalem JOBS=2 ./build.sh --save
```

Result: image `mongodb-no-avx:8.0.17-nehalem` and the file `mongodb-no-avx_8.0.17-nehalem.tar.gz`.

### Resources and duration

The build is memory-hungry: individual translation units need 1.5–2 GB of RAM, the Bazel
server another 2 GB. **What matters is the RAM of the Docker VM**, not that of the host –
with Docker Desktop set it under *Settings → Resources*.

| Docker VM memory | `JOBS` |
|---|---|
| 8 GB | `1` (tight, better increase) |
| 12 GB | `2` |
| 24 GB | `4`–`6` |

Disk space: at least 80 GB (raise the Docker disk limit accordingly).

Reference: Intel Mac, 12 GB Docker VM, `JOBS=2` → roughly 12 hours of build time.
Prefix the call with `caffeinate -i` so the Mac does not go to sleep.

### Abort and resume

If the build aborts (typically `Killed signal terminated program cc1plus` = out of memory),
simply run it again with a smaller `JOBS`. The Bazel cache lives in the Docker volume
`mongod-avx-bazel-cache`; already compiled parts are not repeated.

After a successful build the cache can be removed:

```bash
docker volume rm mongod-avx-bazel-cache
```

### Options

| Variable / option | Default | Meaning |
|---|---|---|
| `CPU_ARCH` | `nehalem` | GCC `-march` target, must not include AVX |
| `JOBS` | all cores | Parallel compiler processes |
| `BAZEL_JVM_MEM` | `2g` | Heap limit of the Bazel server |
| `MONGO_UID` / `MONGO_GID` | `999` | UID/GID of the `mongodb` user in the image |
| `AXCIENT_TAG` / `MONGO_VERSION` | `v8.0.17` / `8.0.17` | Version |
| `IMAGE` | `mongodb-no-avx:<version>-<arch>` | Name of the resulting image |
| `--save` | – | Additionally export the image as `.tar.gz` |
| `--skip-compile` | – | Use the existing `bin/mongod`, only rebuild the image |
| `--from-zip <file>` | – | Take `mongod` from a ZIP (e.g. an Axcient release) |

### AVX spot check

`build.sh` counts instructions using `ymm`/`zmm` registers in the finished binary and lists
the affected functions. The reference build had 11; the image starts and runs in the
reference setup on a CPU without AVX. Such isolated hits are typically code paths that are
only used on suitable CPUs after a runtime CPUID check. The decisive test remains running on
the target machine.

## 3. Transfer to the target host and test (own build)

As a file:

```bash
scp mongodb-no-avx_8.0.17-nehalem.tar.gz user@targethost:/tmp/
ssh user@targethost 'gunzip -c /tmp/mongodb-no-avx_8.0.17-nehalem.tar.gz | docker load'
```

Or via a registry (Docker Hub or ghcr.io):

```bash
docker tag mongodb-no-avx:8.0.17-nehalem ghcr.io/<user>/mongodb-no-avx:8.0.17-nehalem
docker push ghcr.io/<user>/mongodb-no-avx:8.0.17-nehalem
```

Packages on ghcr.io are private initially; the target host then needs `docker login ghcr.io`
with a token that has `read:packages`.

**Smoke test on the target host:**

```bash
docker run --rm mongodb-no-avx:8.0.17-nehalem --version
```

`Illegal instruction` or exit code 132 → the binary is too "modern" for this CPU; rebuild with
`CPU_ARCH=core2` (this changes the compiler flags, so the Bazel cache does not help).

## 4. Updating to a newer 8.0.x

As soon as Axcient publishes a new tag:

```bash
AXCIENT_TAG=v8.0.xx MONGO_VERSION=8.0.xx CPU_ARCH=nehalem JOBS=2 ./build.sh --save
```

Patch updates within 8.0 do not require a change of the feature compatibility version.

## Notes

- Unofficial build, neither tested nor supported by MongoDB. Acceptable for home lab data with
  regular backups, not for production systems.
- MongoDB is licensed under the [SSPL](https://www.mongodb.com/legal/licensing/server-side-public-license).
  Using a self-built image privately is unproblematic; if you distribute it publicly, you
  should know the licence terms.
- Security updates only arrive when you rebuild.
