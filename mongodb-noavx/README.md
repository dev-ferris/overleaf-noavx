# MongoDB 8.0 without AVX

MongoDB 8.0 server built **without the AVX requirement**, for CPUs that cannot run the official
MongoDB images (5.0 and later), e.g. Intel Celeron J4105/J4125, Pentium Silver, Atom and many
NAS / mini-PC systems. The official images abort on these CPUs with `Illegal instruction`.
Built for [Overleaf](https://github.com/dev-ferris/overleaf-noavx) 6.x, which requires MongoDB 8.0,
but usable for anything that needs a MongoDB 8.0 server.

| Registry | Image |
|---|---|
| Docker Hub | [`devferris/mongodb-no-avx`](https://hub.docker.com/r/devferris/mongodb-no-avx) |
| GitHub Container Registry | `ghcr.io/dev-ferris/mongodb-no-avx` (identical, additionally tagged `latest`) |

Source, build script and Dockerfile:
[github.com/dev-ferris/overleaf-noavx](https://github.com/dev-ferris/overleaf-noavx/tree/main/mongodb-noavx)

## Tags

| Tag | MongoDB | Target CPU (`-march`) | `mongodb` UID/GID |
|---|---|---|---|
| `8.0.17-nehalem` | 8.0.17 | `nehalem` – needs SSE4.2 + POPCNT, no AVX | 999 / 999 |

Check your CPU first:

```bash
grep -o -w -E 'avx|sse4_2|popcnt' /proc/cpuinfo | sort -u
```

| Output | Meaning |
|---|---|
| contains `avx` | Use the official `mongo:8.0` image instead |
| `sse4_2` + `popcnt`, no `avx` | This image (`nehalem`) |
| no `sse4_2` | Needs a `core2` build, see [Building it yourself](#building-it-yourself) |

## Usage

The image behaves like the official one for the server part: entrypoint `mongod`, default
command `--bind_ip_all`, runs as user `mongodb`, data in `/data/db`. It is a drop-in
replacement for [`ghcr.io/fenio/mongodb-no-avx`](https://github.com/fenio/mongodb-no-avx)
(MongoDB 7.0 without AVX).
**It contains only `mongod`** – no `mongosh` and no database tools. Use a separate client
image such as `alpine/mongosh` for the shell, `mongodump` and `mongorestore`.

Smoke test on the target machine:

```bash
docker run --rm devferris/mongodb-no-avx:8.0.17-nehalem --version
```

`Illegal instruction` or exit code 132 means the CPU lacks an instruction set this build needs –
see the CPU check above.

Docker Compose with a single-node replica set (as required by e.g. Overleaf):

```yaml
services:
  mongo:
    image: devferris/mongodb-no-avx:8.0.17-nehalem
    command: "--replSet rs0 --bind_ip_all --wiredTigerCacheSizeGB 1"
    environment:
      GLIBC_TUNABLES: glibc.pthread.rseq=0
    volumes:
      - mongo_data:/data/db
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/localhost/27017'"]
      interval: 10s
      timeout: 5s
      retries: 5

  mongo-shell:
    image: alpine/mongosh:latest
    depends_on:
      mongo:
        condition: service_healthy
    entrypoint: ["mongosh", "mongodb://mongo:27017/?directConnection=true", "--quiet", "--eval"]
    command:
      - |
        try { rs.status() }
        catch (e) { rs.initiate({_id: "rs0", members: [{_id: 0, host: "mongo:27017"}]}) }
        while (!db.hello().isWritablePrimary) { sleep(500) }
        print("Replica set ready");

volumes:
  mongo_data:
```

Notes:

- `GLIBC_TUNABLES=glibc.pthread.rseq=0` avoids a tcmalloc performance warning in MongoDB 8
  (the official image sets it as well; newer builds of this image include it).
- Without `--wiredTigerCacheSizeGB`, MongoDB uses about half of the host RAM for its cache.
- The healthcheck is a plain TCP check because the image has no `mongosh`.

### Upgrading from MongoDB 7

MongoDB only upgrades one major version at a time. The data must have feature compatibility
version (FCV) `7.0` before switching the image; raise it to `8.0` afterwards:

```bash
mongosh "mongodb://mongo:27017/?directConnection=true" --eval \
  'db.adminCommand({setFeatureCompatibilityVersion: "8.0", confirm: true})'
```

Take a backup first – going back to 7.0 after raising the FCV requires restoring it.
If you reuse a data volume from another image (e.g. `fenio/mongodb-no-avx:7.0`), make sure
the volume owner matches UID 999, or build yourself with a matching `MONGO_UID`:

```bash
docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28
```

## Building it yourself

Needed for CPUs without SSE4.2 (`core2`), for a different UID (existing volume with another
owner) or for a newer MongoDB version.

The build uses the official MongoDB sources with Bazel on Ubuntu 24.04 and the patches and build
configuration of [Axcient/mongod-avx](https://github.com/Axcient/mongod-avx), which remove AVX
compiler flags (in mozjs and Bazel) and target `-march=nehalem` or `core2`.
[`build.sh`](https://github.com/dev-ferris/overleaf-noavx/blob/main/mongodb-noavx/build.sh) turns
this into a resumable build and a slim runtime image (Ubuntu 24.04 with only the `mongod` binary
and its libraries, see the
[`Dockerfile`](https://github.com/dev-ferris/overleaf-noavx/blob/main/mongodb-noavx/Dockerfile)).

Run it on a powerful x86_64 machine, not on the NAS. Requirements: Docker, x86_64 (Linux or
Intel Mac with Docker Desktop), bash, git.

```bash
git clone https://github.com/dev-ferris/overleaf-noavx.git
cd overleaf-noavx/mongodb-noavx
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
Prefix the call with `caffeinate -i` so the Mac does not go to sleep. Standard GitHub-hosted
Actions runners are not suitable (6-hour job limit, 14 GB disk).

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

### Transfer to the target host

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

Then run the smoke test on the target host. `Illegal instruction` → rebuild with
`CPU_ARCH=core2` (this changes the compiler flags, so the Bazel cache does not help).

### Updating to a newer 8.0.x

As soon as Axcient publishes a new tag:

```bash
AXCIENT_TAG=v8.0.xx MONGO_VERSION=8.0.xx CPU_ARCH=nehalem JOBS=2 ./build.sh --save
```

Patch updates within 8.0 do not require a change of the feature compatibility version.

## Caveats

- **Unofficial build.** Not tested or supported by MongoDB, Inc. Fine for home lab use with
  regular backups; not recommended for production.
- Security updates only arrive when the image is rebuilt from a newer 8.0.x release.
- MongoDB is licensed under the
  [Server Side Public License (SSPL)](https://www.mongodb.com/legal/licensing/server-side-public-license).
  Using a self-built image privately is unproblematic; if you distribute it publicly, you
  should know the licence terms.

## Maintenance (repository)

- This file is also the description of the Docker Hub page. The workflow
  [`dockerhub-description.yml`](https://github.com/dev-ferris/overleaf-noavx/blob/main/.github/workflows/dockerhub-description.yml)
  pushes it on every change; it needs the repository secrets `DOCKERHUB_USERNAME` and
  `DOCKERHUB_TOKEN` (personal access token with scope *Read, Write, Delete*). Use absolute
  links in this file – relative links do not resolve on Docker Hub.
- The GHCR copy is created by the workflow
  [`mirror-mongodb-image.yml`](https://github.com/dev-ferris/overleaf-noavx/blob/main/.github/workflows/mirror-mongodb-image.yml)
  (trigger it manually under *Actions*, e.g. after a new build).

## Credits

- [Axcient/mongod-avx](https://github.com/Axcient/mongod-avx) – patches and Bazel configuration for MongoDB 8.0 without AVX
- [fenio/mongodb-no-avx](https://github.com/fenio/mongodb-no-avx) – MongoDB 7.0 without AVX, template for the runtime image
- Created with the help of [Claude](https://www.anthropic.com/claude), an AI assistant by Anthropic
