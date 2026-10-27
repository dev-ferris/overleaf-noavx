# Migration: Overleaf CEP 5.5 + MongoDB 7 → Overleaf CEP 6.3 + MongoDB 8

Starting point:

| Component | Before | After |
|---|---|---|
| Overleaf | `overleafcep/sharelatex:5.5.6-ext-v3.3` | `overleafcep/sharelatex:6.3.0-ext-v5.1` |
| MongoDB | `ghcr.io/fenio/mongodb-no-avx:7.0.28` | `devferris/mongodb-no-avx:8.0.17-nehalem` (or own build) |
| Redis | `valkey/valkey:9.2-alpine` | `redis:7.4-alpine` (or keep Valkey, see phase 3) |
| TeX Live | `texlive-init` volume (fixed release year) | `texlive-init` volume with update detection and `PATH` |

Overleaf 6 requires:

1. the **binary files migration** from 5.5 has been completed,
2. **MongoDB ≥ 8.0**,
3. **Redis ≥ 7.4** (Valkey 9.2 reports `redis_version:7.2.4`),
4. the secret **`OVERLEAF_INVITE_TOKEN_SECRET`** is set (since 6.2).

The order of the phases matters. Phases 0–3 run with the **old** compose file; only phase 4
switches to [`../overleaf/docker-compose.yml`](../overleaf/docker-compose.yml).

All commands run in the old compose directory unless stated otherwise.
Prerequisite: the `mongo-shell` service is defined as follows (the old `sleep infinity` variant
does not work with `--eval`):

```yaml
  mongo-shell:
    image: alpine/mongosh:latest
    profiles: ["tools"]
    entrypoint: ["mongosh", "mongodb://mongo:27017/?directConnection=true"]
    depends_on:
      - mongo
```

---

## Phase 0 – Inventory and backup

**Identify the volumes.** The prefix is the compose project name (usually the directory name):

```bash
docker volume ls | grep -E 'mongo_data|sharelatex_data|redis_data'
PROJECT=$(basename "$PWD")     # adjust if the prefix differs
```

**Check that this is the right MongoDB volume** – the old one has FCV 7.0:

```bash
docker compose run --rm mongo-shell --quiet --eval \
  'db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1})'
```

MongoDB can only be upgraded one major version at a time. If it shows `6.0`, raise it first
while still on the 7.0 image:

```bash
docker compose run --rm mongo-shell --quiet --eval \
  'db.adminCommand({setFeatureCompatibilityVersion: "7.0", confirm: true})'
```

**Backup** with everything stopped:

```bash
docker compose stop sharelatex mongo redis
mkdir -p backup
for v in mongo_data sharelatex_data redis_data; do
  docker run --rm -v ${PROJECT}_${v}:/data:ro -v "$PWD/backup":/backup alpine \
    tar czf /backup/${v}-pre-v6-$(date +%F).tgz -C /data .
done
cp .env docker-compose.yml backup/
```

This is the only way back: a downgrade from 6.x to 5.5 requires a full backup.

---

## Phase 1 – Binary files migration (Overleaf 5.5.6-ext, MongoDB 7)

Upstream requires 5.5.7; the CEP names `5.5.6-ext-vX.Y` as the prerequisite for 6.0.0-ext.
First check that the migration script is in the image:

```bash
docker compose up -d
docker compose exec sharelatex ls /overleaf/services/history-v1/storage/scripts/back_fill_file_hash.mjs
```

If the file is missing: stop here.

**1. Estimate the scope**

```bash
docker compose exec sharelatex /bin/bash -c "source /etc/overleaf/env.sh && source /etc/container_environment.sh && cd /overleaf/services/history-v1 && /sbin/setuser www-data node storage/scripts/back_fill_file_hash.mjs --report"
```

**2. Flush the history queues** – repeat until `"project_ids":0`. If `failedProjects` ≠ 0: stop.

```bash
docker compose exec sharelatex /overleaf/bin/flush-history-queues
```

**3. Set level 1** – in `.env`:

```env
OVERLEAF_FILESTORE_MIGRATION_LEVEL=1
```

```bash
docker compose up -d
```

Open a project and display an image in it.

**4. Run the migration**

```bash
docker compose exec sharelatex /bin/bash -c "source /etc/overleaf/env.sh && source /etc/container_environment.sh && cd /overleaf/services/history-v1 && /sbin/setuser www-data node storage/scripts/back_fill_file_hash.mjs --all"
```

Success: the output ends with `Done.`, no errors, exit code 0. The log is written to
`/var/log/overleaf/file-migration-<timestamp>.log`. The script can be interrupted and restarted;
files already processed are skipped.

**5. Move the old files aside** (do not delete)

```bash
docker compose stop sharelatex
docker compose run --rm --entrypoint mv sharelatex --no-clobber --verbose \
  /var/lib/overleaf/data/user_files /var/lib/overleaf/data/old_user_files
```

If `user_files` does not exist, no binary files were ever uploaded – skip this step.

**6. Set level 2** – in `.env`:

```env
OVERLEAF_FILESTORE_MIGRATION_LEVEL=2
```

```bash
docker compose up -d
```

Open a project with images: images visible, project compiles → migration successful.

---

## Phase 2 – MongoDB 7 → 8

Pull and test the image:

```bash
docker pull devferris/mongodb-no-avx:8.0.17-nehalem
docker run --rm devferris/mongodb-no-avx:8.0.17-nehalem --version
```

Alternatively build it yourself: [`../mongodb-noavx`](../mongodb-noavx). The UID of the
`mongodb` user in the prebuilt image is 999 – compare with the old image
(`docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28`); if it differs,
build yourself with a matching `MONGO_UID`/`MONGO_GID`.

```bash
docker compose stop sharelatex
```

In the old compose file only swap the image of the `mongo` service – volume and `--replSet rs0` stay:

```yaml
  mongo:
    image: devferris/mongodb-no-avx:8.0.17-nehalem
    command: "--replSet rs0 --bind_ip_all --wiredTigerCacheSizeGB 1"
    environment:
      GLIBC_TUNABLES: glibc.pthread.rseq=0
```

```bash
docker compose up -d mongo
docker compose logs mongo | grep -iE 'error|denied|illegal' # should be empty
docker compose run --rm mongo-shell --quiet --eval 'db.version()'                          # 8.0.17
docker compose run --rm mongo-shell --quiet --eval 'rs.status().members.map(m => m.stateStr)'  # [ 'PRIMARY' ]
```

`Permission denied` on `/data/db` → rebuild the image with a matching `MONGO_UID`/`MONGO_GID`
(`./build.sh --skip-compile`), see the build README.

**Briefly test Overleaf 5.5 with MongoDB 8** (login, open a project):

```bash
docker compose up -d sharelatex
```

**Raise the FCV** – afterwards going back to MongoDB 7 is only possible via the backup:

```bash
docker compose run --rm mongo-shell --quiet --eval \
  'db.adminCommand({setFeatureCompatibilityVersion: "8.0", confirm: true})'
```

---

## Phase 3 – Prepare Redis

Overleaf 6 officially requires Redis ≥ 7.4. Valkey 9.2 reports `redis_version:7.2.4` but
supports the required commands. Two options:

- **Keep Valkey:** in phase 4 set `REDIS_IMAGE=valkey/valkey:9.2-alpine` in `.env`;
  the existing volume is reused. Skip this phase.
- **Switch to Redis 7.4** (officially supported): as follows.

Redis only holds queues and sessions. With the queues flushed, Redis 7.4 can start empty;
the Valkey 9 volume is discarded (Redis 7.4 cannot reliably read Valkey 9 dumps).

```bash
docker compose exec sharelatex /overleaf/bin/flush-history-queues   # "project_ids":0
docker compose down                                                   # volumes are kept
docker volume rm ${PROJECT}_redis_data                                # backed up in phase 0
```

Consequence: all users have to log in once again.

---

## Phase 4 – Overleaf CEP 6.3 with the new compose file

Get the repository onto the host and take over the configuration:

```bash
cd /path/to/overleaf-noavx/overleaf
cp .env.example .env
cp overleaf.env.example overleaf.env
```

**`.env`:**

- `COMPOSE_PROJECT_NAME` = **old prefix** (`$PROJECT` from phase 0). Otherwise Compose creates
  new, empty volumes and Overleaf starts like a fresh installation.
- Adjust `MONGO_IMAGE`, `OVERLEAF_BIND`; with Valkey also `REDIS_IMAGE` (see phase 3).
- The compose file no longer contains a reverse proxy. If Overleaf previously ran behind Caddy
  (labels), point the proxy to the published port, see
  [`../overleaf/README.md`](../overleaf/README.md#https-via-a-reverse-proxy-optional).
  Carry over `OVERLEAF_SITE_URL` and `OVERLEAF_SECURE_COOKIE` accordingly.

**`overleaf.env`:** carry over the values from the old `.env` (`OVERLEAF_SITE_URL`, app name,
template gallery …). Do not carry over: `OVERLEAF_MONGO_URL`/`REDIS_HOST` (set by the compose
file) and variables with the value `false` – some take effect as soon as they are set (see the
comment in `overleaf.env.example`). Add:

```env
OVERLEAF_INVITE_TOKEN_SECRET=<openssl rand -base64 32>
OVERLEAF_FILESTORE_MIGRATION_LEVEL=2
```

**TeX Live:** the new compose file again uses a volume called `texlive` – with the same project
name, i.e. the **existing** `${PROJECT}_texlive`. The old volume has no marker; `texlive-init`
detects this, empties it and copies the current release year into it. In addition, the compose
file sets `PATH` to `/usr/local/texlive/current/...`, so the TeX Live year no longer has to
match the Overleaf image (that was the weak spot of the old setup). Details:
[`../overleaf/README.md`](../overleaf/README.md#tex-live).

**Start:**

```bash
docker volume ls | grep "^local *${PROJECT}_"     # mongo_data and sharelatex_data must be listed
docker compose pull                                # TeX Live image: several GB, takes a while
docker compose up -d
docker compose logs -f texlive-init                # copies TeX Live into the volume, a few minutes
docker compose logs -f sharelatex
```

On the first start the database migrations from 5.5 to 6.3 run; this takes a few minutes.
`mongo-shell` reports "Replica set already initialised" and "Replica set ready" – the replica
set is taken over from the existing volume. If the old compose file has a `mongo-shell`
service of the same name (e.g. with `sleep infinity`), the new one replaces it.

**Check:** login, open an existing project, images visible, compile (including a KOMA-Script
letter with `scrlttr2`), open the history, invite a second user.

---

## Phase 5 – Cleanup (after a few days without problems)

```bash
docker compose run --rm --entrypoint rm sharelatex -rf /var/lib/overleaf/data/old_user_files
```

Keep the backups from phase 0 for a while.

---

## Rollback

Before phase 4: restore the old compose file from `backup/` and restore the MongoDB volume from
the backup (MongoDB 7 cannot open FCV 8.0).

After phase 4: restore all three volumes from the backup and use the old compose file:

```bash
docker compose down
for v in mongo_data sharelatex_data redis_data; do
  docker volume rm ${PROJECT}_${v}; docker volume create ${PROJECT}_${v}
  docker run --rm -v ${PROJECT}_${v}:/data -v "$PWD/backup":/backup alpine \
    tar xzf /backup/${v}-pre-v6-<DATE>.tgz -C /data
done
```

## Sources

- [Overleaf: Binary files migration](https://docs.overleaf.com/on-premises/release-notes/release-notes-5.x.x/binary-files-migration)
- [Overleaf: Release notes 6.x.x](https://docs.overleaf.com/on-premises/release-notes/release-notes-6.x.x)
- [Overleaf CE+ wiki and release notes](https://github.com/yu-i-i/overleaf-cep/wiki)
