# MongoDB 8.0 without AVX

MongoDB 8.0 server built **without the AVX requirement**, for CPUs that cannot run the official
MongoDB images (5.0 and later), e.g. Intel Celeron J4105/J4125, Pentium Silver, Atom and many
NAS / mini-PC systems. The official images abort on these CPUs with `Illegal instruction`.

- **Source and build scripts:** [github.com/dev-ferris/overleaf-noavx](https://github.com/dev-ferris/overleaf-noavx) (directory `mongodb-noavx/`)
- **Also available as:** `ghcr.io/dev-ferris/mongodb-no-avx`

## Tags

| Tag | MongoDB | Target CPU (`-march`) | `mongodb` UID/GID |
|---|---|---|---|
| `8.0.17-nehalem` | 8.0.17 | `nehalem` – needs SSE4.2 + POPCNT, no AVX | 999 / 999 |

Check your CPU first:

```bash
grep -o -w -E 'avx|sse4_2|popcnt' /proc/cpuinfo | sort -u
```

- `avx` listed → use the official `mongo:8.0` image instead.
- `sse4_2` and `popcnt`, no `avx` → this image (`nehalem`).
- no `sse4_2` → needs a `core2` build, see the build instructions in the GitHub repository.

## Usage

The image behaves like the official one for the server part: entrypoint `mongod`, default
command `--bind_ip_all`, runs as user `mongodb`, data in `/data/db`.
**It contains only `mongod`** – no `mongosh` and no database tools. Use a separate client
image such as `alpine/mongosh` for the shell, `mongodump` and `mongorestore`.

Smoke test on the target machine:

```bash
docker run --rm devferris/mongodb-no-avx:8.0.17-nehalem --version
```

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
the volume owner matches UID 999, or rebuild with a matching `MONGO_UID`.

## How it is built

From the official MongoDB sources with Bazel on Ubuntu 24.04, using the patches and build
configuration of [Axcient/mongod-avx](https://github.com/Axcient/mongod-avx), which remove AVX
compiler flags and target `-march=nehalem`. The runtime image is a slim Ubuntu 24.04 with only
the `mongod` binary and its libraries. Build script and Dockerfile are in the GitHub repository.

## Caveats

- **Unofficial build.** Not tested or supported by MongoDB, Inc. Fine for home lab use with
  regular backups; not recommended for production.
- Security updates only arrive when the image is rebuilt from a newer 8.0.x release.
- MongoDB is licensed under the
  [Server Side Public License (SSPL)](https://www.mongodb.com/legal/licensing/server-side-public-license).

## Credits

- [Axcient/mongod-avx](https://github.com/Axcient/mongod-avx) – patches and Bazel configuration for MongoDB 8.0 without AVX
- [fenio/mongodb-no-avx](https://github.com/fenio/mongodb-no-avx) – MongoDB 7.0 without AVX, template for the runtime image
