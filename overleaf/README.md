# Overleaf CEP 6.x – new installation with Docker Compose

Setup for [Overleaf Extended Community Edition (CEP)](https://github.com/yu-i-i/overleaf-cep)
with MongoDB 8 without AVX, Redis 7.4 and a **full TeX Live** (via a volume, no Docker socket).
Overleaf is reachable directly via HTTP on a port; a reverse proxy for HTTPS is optional
and not part of the compose file.

For an **upgrade of an existing 5.5 installation** follow
[`../docs/migration-5.5-to-6.3.md`](../docs/migration-5.5-to-6.3.md) instead.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Redis, MongoDB, `mongo-shell` (replica set init + shell), TeX Live volume, Overleaf |
| `.env.example` | Compose variables: images, port, project name |
| `overleaf.env.example` | Overleaf configuration including secrets |

## Requirements

- MongoDB image without AVX: the default is [`devferris/mongodb-no-avx:8.0.17-nehalem`](https://hub.docker.com/r/devferris/mongodb-no-avx)
  from Docker Hub (pulled on the first `up`). To build it yourself see [`../mongodb-noavx`](../mongodb-noavx);
  on a CPU with AVX use `MONGO_IMAGE=mongo:8.0` instead
- About 15 GB of free space for TeX Live: the image and its copy in the volume take several GB each

## Setup

```bash
cp .env.example .env
cp overleaf.env.example overleaf.env
openssl rand -base64 32        # -> OVERLEAF_INVITE_TOKEN_SECRET in overleaf.env
```

In `.env` adjust: `OVERLEAF_BIND` (port, default 8088), `MONGO_IMAGE`.
In `overleaf.env` adjust: `OVERLEAF_SITE_URL` (exactly the address in the browser, including port),
`OVERLEAF_INVITE_TOKEN_SECRET`, `OVERLEAF_ADMIN_EMAIL`.

```bash
docker compose pull                    # TeX Live image: several GB, takes a while
docker compose up -d
docker compose logs -f texlive-init    # first start: copies TeX Live into the volume, a few minutes
docker compose logs -f sharelatex      # then: migrations, a few minutes
```

Compose enforces the start order: `mongo` (healthy) → `mongo-shell` (replica set with a
primary, healthy) → `redis` (healthy) → `texlive-init` (TeX Live in the volume) → `sharelatex`.
`mongo-shell` keeps running afterwards and serves as the MongoDB shell (`docker compose exec mongo-shell mongosh ...`).

### Create the first administrator

Open `http://<host>:8088/launchpad` in the browser and create an account – the page only
exists as long as there is no admin yet. Alternatively:

```bash
docker compose exec sharelatex bash -c \
  "cd /overleaf/services/web && node modules/server-ce-scripts/scripts/create-user.mjs --admin --email=you@example.com"
```

The script prints a link for setting the password. Further users under *Admin → Manage Users*.

## HTTPS via a reverse proxy (optional)

The compose file only publishes HTTP on `OVERLEAF_BIND`. For HTTPS put any reverse proxy
(Caddy, Traefik, nginx …) in front:

1. Let the proxy forward to `http://<host>:8088`. **WebSockets** must be passed through
   (real-time editor); Caddy and Traefik do this automatically, for nginx set
   `proxy_set_header Upgrade` / `Connection "upgrade"`.
2. If the proxy runs directly on the same host: `OVERLEAF_BIND=127.0.0.1:8088` in `.env`, so
   that Overleaf is not additionally reachable unencrypted on the network. If the proxy itself
   runs in a container, it cannot reach the host's `127.0.0.1` – use the host's LAN IP then.
3. In `overleaf.env`:

```env
OVERLEAF_SITE_URL=https://overleaf.example.com
OVERLEAF_SECURE_COOKIE=true
```

Then run `docker compose up -d --force-recreate sharelatex`.

Example Caddyfile:

```caddyfile
overleaf.example.com {
    reverse_proxy 127.0.0.1:8088
}
```

## TeX Live

The Overleaf image itself only contains a minimal TeX Live (`scheme-basic`); classes such as
`scrlttr2` (KOMA-Script) are missing. This setup replaces it with the **full** TeX Live from
[`texlive/texlive:latest`](https://hub.docker.com/r/texlive/texlive) – all CTAN packages,
`latexmk`, `biber`, `xindy` etc. – mounted as a volume, without a Docker socket.

| Part | Role |
|---|---|
| Service `texlive-init` | Copies `/usr/local/texlive` from the TeX Live image into the volume `texlive`, creates the link `current` → release year, checks `latexmk`/`pdflatex`, exits |
| Volume `texlive` → `/usr/local/texlive:ro` | Replaces the minimal TeX Live in the Overleaf container |
| `PATH` in service `sharelatex` | `/usr/local/texlive/current/bin/x86_64-linux` comes first; Overleaf calls `latexmk` via `PATH` |

**Why the `current` link and `PATH`:** The Overleaf image links its TeX binaries in
`/usr/local/bin` to a fixed release year (`/usr/local/texlive/<year>/...`). If the volume comes
from a different year, those links would point nowhere. With `current` and `PATH`, the TeX
Live year of the Overleaf image no longer matters.

**Update / switch the release year:** change `TEXLIVE_IMAGE` in `.env` or pull a newer image, then:

```bash
docker compose pull texlive-init
docker compose stop sharelatex         # do not compile while copying
docker compose up -d
```

`texlive-init` detects the change (marker made of release year and checksum of the package
database) and copies again, then `sharelatex` starts. Without a change, `texlive-init` is done
within seconds and leaves the volume untouched – a normal `docker compose up -d` is therefore
always safe.

**Check which TeX Live Overleaf uses:**

```bash
docker compose exec sharelatex bash -c 'which latexmk; pdflatex --version | head -1; kpsewhich scrlttr2.cls'
```

**Saving space:** after copying, the image is only needed for updates.
`docker image rm texlive/texlive:latest` frees several GB; the next `docker compose up` will
pull it again, though.

**`-shell-escape`** (e.g. for `minted`): `TEX_COMPILER_EXTRA_FLAGS=-shell-escape` in
`overleaf.env`. Without a sandbox the commands run directly in the Overleaf container – only
with trusted users.

### Alternative: sandboxed compiles

The CEP can also compile every project in its own TeX Live container (release year selectable
per project, isolation). That, however, requires the Docker socket in the Overleaf container,
effectively root access to the host, and is therefore not used here. See
[CEP wiki: Sandboxed Compiles](https://github.com/yu-i-i/overleaf-cep/wiki/Extended-CE:-Sandboxed-Compiles).

## Operation

**MongoDB shell:**

```bash
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true"   # interactive
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval 'rs.status().members.map(m => m.stateStr)'
```

**List / grant / revoke admins:**

```bash
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval \
  'db.getSiblingDB("sharelatex").users.find({isAdmin: true}, {email: 1}).toArray()'
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval \
  'db.getSiblingDB("sharelatex").users.updateOne({email: "you@example.com"}, {$set: {isAdmin: true}})'
```

## Backup

Consistent backup: MongoDB via `mongodump` (runs while the database is up, `--oplog` ensures a
consistent state), `sharelatex_data` with Overleaf stopped. Not backed up: `mongo_data` (raw
files of a running database are not a reliable backup) and `texlive` (reproducible from the
image at any time).

Run in the `overleaf/` directory:

```bash
PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)
TARGET=backup/$(date +%F_%H%M) && mkdir -p "$TARGET"

# MongoDB
docker compose exec mongo-shell mongodump --quiet \
  --uri="mongodb://mongo:27017/?directConnection=true" --oplog --gzip --archive=/tmp/mongo.archive.gz
docker compose cp mongo-shell:/tmp/mongo.archive.gz "$TARGET/"
docker compose exec mongo-shell rm -f /tmp/mongo.archive.gz

# Overleaf files and Redis
docker compose stop sharelatex redis
for v in sharelatex_data redis_data; do
  docker run --rm -v ${PROJECT}_${v}:/data:ro -v "$PWD/$TARGET":/backup alpine \
    tar czf /backup/${v}.tgz -C /data .
done
docker compose start redis sharelatex

# Configuration (contains OVERLEAF_INVITE_TOKEN_SECRET)
cp .env overleaf.env "$TARGET/"
```

For regular backups this can be run as a script via cron. Since `mongo-shell` runs
permanently, a backup tool can also trigger `mongodump` in it via `docker exec`.

### Restore

Run in the `overleaf/` directory. On a new host, first take over the configuration from the
backup (`cp backup/<timestamp>/{.env,overleaf.env} .`) – it contains the project name and
`OVERLEAF_INVITE_TOKEN_SECRET`.

```bash
SOURCE=backup/<timestamp>
PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)

docker compose up -d mongo mongo-shell          # MongoDB + replica set
docker compose stop sharelatex redis 2>/dev/null || true

# Overleaf files and Redis (content is replaced!)
for v in sharelatex_data redis_data; do
  docker volume create ${PROJECT}_${v} >/dev/null
  docker run --rm -v ${PROJECT}_${v}:/data -v "$PWD/$SOURCE":/backup:ro alpine \
    sh -c 'find /data -mindepth 1 -delete && tar xzf /backup/'${v}'.tgz -C /data'
done

# MongoDB (--drop replaces existing collections)
docker compose cp "$SOURCE/mongo.archive.gz" mongo-shell:/tmp/mongo.archive.gz
docker compose exec mongo-shell mongorestore --uri="mongodb://mongo:27017/?directConnection=true" \
  --oplogReplay --drop --gzip --archive=/tmp/mongo.archive.gz
docker compose exec mongo-shell rm -f /tmp/mongo.archive.gz

docker compose up -d
```

If something goes wrong: [`../docs/troubleshooting.md`](../docs/troubleshooting.md).
