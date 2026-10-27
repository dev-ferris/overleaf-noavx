# Troubleshooting

Common errors with cause and fix – most of them actually occurred while setting up this stack.

## Overleaf

### "Session error. Please check you have cookies enabled."

**Cause:** secure cookies while accessing via HTTP. Overleaf only checks whether
`OVERLEAF_SECURE_COOKIE` is *set* (`process.env.OVERLEAF_SECURE_COOKIE != null`) –
`OVERLEAF_SECURE_COOKIE=false` therefore turns secure cookies **on**. The browser drops the
cookie over HTTP, and the login fails the CSRF check.

**Fix:** for HTTP access remove or comment out the line; only set it for HTTPS.
`OVERLEAF_SITE_URL` must match the address in the browser exactly (including port).
Changes to env files require `docker compose up -d --force-recreate sharelatex`;
a `restart` is not enough.

### "Missing required secrets: OVERLEAF_INVITE_TOKEN_SECRET", container restarts in a loop

Required since 6.2. Generate `openssl rand -base64 32` once, put it into `overleaf.env` and
never change it (otherwise pending invitations become invalid). Do not generate it dynamically
in the compose file.

### `LaTeX Error: File 'scrlttr2.cls' not found`

Overleaf compiles with the minimal TeX Live of the image instead of the volume. Check:

```bash
docker compose exec sharelatex bash -c 'which latexmk; kpsewhich scrlttr2.cls'
```

Expected: `/usr/local/texlive/current/bin/x86_64-linux/latexmk` and a path to `scrlttr2.cls`.
If `which` points to `/usr/local/bin/...`, the `PATH` variable in the `sharelatex` service is
missing or the `texlive` volume is not mounted. After changes run
`docker compose up -d --force-recreate sharelatex`.

`tlmgr install` in the running Overleaf container is no solution – the package is gone when
the container is recreated.

### `texlive-init` aborts, `sharelatex` does not start

```bash
docker compose logs texlive-init
```

| Message | Cause |
|---|---|
| `no TeX Live release year found under /usr/local/texlive` | `TEXLIVE_IMAGE` is not a texlive/texlive image or has a different layout |
| `latexmk missing` | Image without `latexmk` (e.g. `latest-minimal`) – use `latest` |
| `No space left on device` | The volume needs about as much space again as the image |

An interrupted copy is repeated automatically on the next `docker compose up -d`
(the marker is only written at the end).

### `pdflatex` not found

Classic error of the old setup: a TeX Live volume from a different release year sits on top of
`/usr/local/texlive`, and the Overleaf image's symlinks in `/usr/local/bin` point nowhere.
With this compose file the `PATH` to `current` prevents that. If it still happens, check `PATH`
in the `sharelatex` service (`docker compose config | grep PATH`).

### Overleaf hangs at startup, log shows Mongo timeouts

Usually the replica set is not initialised or registered with the wrong host name
(container ID instead of `mongo:27017`):

```bash
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval 'rs.conf().members.map(m => m.host)'
```

Fix a wrong host:

```bash
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval \
  'c = rs.conf(); c.members[0].host = "mongo:27017"; rs.reconfig(c, {force: true})'
```

### `rs.initiate(...)`: "bash: syntax error near unexpected token"

The command is JavaScript and belongs in `mongosh`, not in the container's bash.
The no-AVX image has no mongosh – run it via the `mongo-shell` container
(with the compose file from this repository `mongo-shell` does this automatically at startup anyway):

```bash
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval \
  'rs.initiate({_id: "rs0", members: [{_id: 0, host: "mongo:27017"}]})'
```

### Reverse proxy: 502 or the editor does not connect

502: the proxy cannot reach `http://<host>:<OVERLEAF_BIND>` – check port and bind address in
`.env` (`127.0.0.1:…` is only reachable from the host itself, not from another container).
Page loads but the editor stays at "Connecting": WebSockets are not passed through, see
[`../overleaf/README.md`](../overleaf/README.md#https-via-a-reverse-proxy-optional).

### `user_files` no longer exists after the binary files migration

Expected: step 5 of the [binary files migration](migration-5.5-to-6.3.md#phase-1--binary-files-migration-overleaf-556-ext-mongodb-7)
renames it to `old_user_files`; with level 2 the files live in the history. If `user_files`
never existed, no binary files were ever uploaded.

```bash
docker compose run --rm --entrypoint ls sharelatex -la /var/lib/overleaf/data/
```

## MongoDB

### `sharelatex` does not start, waits for `mongo-shell`

`mongo-shell` only becomes *healthy* once the replica set has a writable primary:

```bash
docker compose logs mongo-shell
```

If `mongo-shell` aborts because MongoDB was not reachable yet at startup,
`restart: unless-stopped` restarts it. If it stays unhealthy: check `docker compose logs mongo`
(permissions, `Illegal instruction`).

### `Illegal instruction` / exit code 132

The CPU cannot execute instructions contained in the binary: either official MongoDB ≥ 5.0 on a
CPU without AVX, or the custom build uses a too modern `CPU_ARCH`. Rebuild with `CPU_ARCH=core2`.

### `Permission denied` on `/data/db`

The UID of the `mongodb` user in the new image does not match the owner of the existing volume.
Determine the UID in the old image and rebuild (takes only minutes):

```bash
docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28
MONGO_UID=<uid> MONGO_GID=<gid> ./build.sh --skip-compile --save
```

### Startup warnings in the MongoDB log

| Warning | Assessment |
|---|---|
| `glibc support for rseq ... GLIBC_TUNABLES=glibc.pthread.rseq=0` | Set in the compose file (and in the current Dockerfile); add `GLIBC_TUNABLES` to your own compose file |
| `cache_size=15460M` or similar | Set `--wiredTigerCacheSizeGB`, otherwise MongoDB takes ~50 % of the RAM |
| `Access control is not enabled` | Intended, as long as port 27017 is not published |
| `transparent_hugepage`, `swappiness` | Kernel settings of the host, not critical for a home lab |

## MongoDB build

### `cannot allocate memory` / `Killed signal terminated program cc1plus`

Out of memory in the Docker VM. Increase Docker Desktop's memory and/or reduce `JOBS`, then
simply start again – the Bazel cache in the volume `mongod-avx-bazel-cache` makes it continue
where it stopped. If more than two compilers run at the same time despite `JOBS=2`, `JOBS` was
not passed (set the variable on the same line as the command).

### `libatomic.so.1 => not found` while building the runtime image

The runtime image needs `libatomic1`; it is included in this repository's Dockerfile. With a
customised Dockerfile, add it and rebuild without compiling again:
`./build.sh --skip-compile --save`.
