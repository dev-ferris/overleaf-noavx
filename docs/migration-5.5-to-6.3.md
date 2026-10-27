# Migration: Overleaf CEP 5.5 + MongoDB 7 → Overleaf CEP 6.3 + MongoDB 8

Ausgangslage:

| Komponente | Vorher | Nachher |
|---|---|---|
| Overleaf | `overleafcep/sharelatex:5.5.6-ext-v3.3` | `overleafcep/sharelatex:6.3.0-ext-v5.1` |
| MongoDB | `ghcr.io/fenio/mongodb-no-avx:7.0.28` | `devferris/mongodb-no-avx:8.0.17-nehalem` (oder Eigenbau) |
| Redis | `valkey/valkey:9.2-alpine` | `redis:7.4-alpine` |
| TeX Live | `texlive-init`-Volume (fester Jahrgang) | `texlive-init`-Volume mit Update-Erkennung und `PATH` |

Overleaf 6 setzt voraus:

1. die **Binary-File-Migration** aus 5.5 ist abgeschlossen,
2. **MongoDB ≥ 8.0**,
3. **Redis ≥ 7.4** (Valkey 9.2 meldet sich als `redis_version:7.2.4`),
4. das Secret **`OVERLEAF_INVITE_TOKEN_SECRET`** ist gesetzt (seit 6.2).

Die Reihenfolge der Phasen ist wichtig. Phasen 0–3 laufen mit der **alten** Compose-Datei,
erst Phase 4 wechselt auf [`../overleaf/docker-compose.yml`](../overleaf/docker-compose.yml).

Alle Befehle im alten Compose-Verzeichnis, sofern nicht anders angegeben.
Voraussetzung: Der `mongo-shell`-Service ist wie folgt definiert (das alte `sleep infinity`
funktioniert mit `--eval` nicht):

```yaml
  mongo-shell:
    image: alpine/mongosh:latest
    profiles: ["tools"]
    entrypoint: ["mongosh", "mongodb://mongo:27017/?directConnection=true"]
    depends_on:
      - mongo
```

---

## Phase 0 – Bestandsaufnahme und Backup

**Volumes identifizieren.** Der Präfix ist der Compose-Projektname (meist der Verzeichnisname):

```bash
docker volume ls | grep -E 'mongo_data|sharelatex_data|redis_data'
PROJECT=$(basename "$PWD")     # anpassen, falls der Präfix anders lautet
```

**Prüfen, dass es das richtige MongoDB-Volume ist** – das alte hat FCV 7.0:

```bash
docker compose run --rm mongo-shell --quiet --eval \
  'db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1})'
```

**Backup** im gestoppten Zustand:

```bash
docker compose stop sharelatex mongo redis
mkdir -p backup
for v in mongo_data sharelatex_data redis_data; do
  docker run --rm -v ${PROJECT}_${v}:/data:ro -v "$PWD/backup":/backup alpine \
    tar czf /backup/${v}-pre-v6-$(date +%F).tgz -C /data .
done
cp .env docker-compose.yml backup/
```

Das ist der einzige Rückweg: Ein Downgrade von 6.x auf 5.5 geht nur über ein vollständiges Backup.

---

## Phase 1 – Binary-File-Migration (Overleaf 5.5.6-ext, MongoDB 7)

Upstream verlangt 5.5.7; die CEP nennt `5.5.6-ext-vX.Y` als Voraussetzung für 6.0.0-ext.
Erst prüfen, ob das Migrationsskript im Image ist:

```bash
docker compose up -d
docker compose exec sharelatex ls /overleaf/services/history-v1/storage/scripts/back_fill_file_hash.mjs
```

Fehlt die Datei: hier stoppen.

**1. Umfang ermitteln**

```bash
docker compose exec sharelatex /bin/bash -c "source /etc/overleaf/env.sh && source /etc/container_environment.sh && cd /overleaf/services/history-v1 && /sbin/setuser www-data node storage/scripts/back_fill_file_hash.mjs --report"
```

**2. History-Queues leeren** – wiederholen bis `"project_ids":0`. Ist `failedProjects` ≠ 0: stoppen.

```bash
docker compose exec sharelatex /overleaf/bin/flush-history-queues
```

**3. Stufe 1 setzen** – in `.env`:

```env
OVERLEAF_FILESTORE_MIGRATION_LEVEL=1
```

```bash
docker compose up -d
```

Ein Projekt öffnen und ein Bild darin anzeigen lassen.

**4. Migration ausführen**

```bash
docker compose exec sharelatex /bin/bash -c "source /etc/overleaf/env.sh && source /etc/container_environment.sh && cd /overleaf/services/history-v1 && /sbin/setuser www-data node storage/scripts/back_fill_file_hash.mjs --all"
```

Erfolg: Ausgabe endet mit `Done.`, keine Fehler, Exit-Code 0. Das Log liegt unter
`/var/log/overleaf/file-migration-<timestamp>.log`. Das Skript kann abgebrochen und erneut
gestartet werden, bereits verarbeitete Dateien werden übersprungen.

**5. Alte Dateien beiseiteschieben** (nicht löschen)

```bash
docker compose stop sharelatex
docker compose run --rm --entrypoint mv sharelatex --no-clobber --verbose \
  /var/lib/overleaf/data/user_files /var/lib/overleaf/data/old_user_files
```

Gibt es `user_files` nicht, wurden nie Binärdateien hochgeladen – dann entfällt dieser Schritt.

**6. Stufe 2 setzen** – in `.env`:

```env
OVERLEAF_FILESTORE_MIGRATION_LEVEL=2
```

```bash
docker compose up -d
```

Projekt mit Bildern öffnen: Bilder sichtbar, Projekt kompiliert → Migration erfolgreich.

---

## Phase 2 – MongoDB 7 → 8

Image ziehen und testen:

```bash
docker pull devferris/mongodb-no-avx:8.0.17-nehalem
docker run --rm devferris/mongodb-no-avx:8.0.17-nehalem --version
```

Alternativ selbst bauen: [`../mongodb-noavx`](../mongodb-noavx). Die UID des `mongodb`-Users
im fertigen Image ist 999 – mit dem alten Image vergleichen
(`docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28`); weicht sie ab,
selbst bauen mit passender `MONGO_UID`/`MONGO_GID`.

```bash
docker compose stop sharelatex
```

Im alten Compose nur das Image des `mongo`-Service tauschen – Volume und `--replSet rs0` bleiben:

```yaml
  mongo:
    image: devferris/mongodb-no-avx:8.0.17-nehalem
    command: "--replSet rs0 --bind_ip_all --wiredTigerCacheSizeGB 1"
    environment:
      GLIBC_TUNABLES: glibc.pthread.rseq=0
```

```bash
docker compose up -d mongo
docker compose logs mongo | grep -iE 'error|denied|illegal' # sollte leer sein
docker compose run --rm mongo-shell --quiet --eval 'db.version()'                          # 8.0.17
docker compose run --rm mongo-shell --quiet --eval 'rs.status().members.map(m => m.stateStr)'  # [ 'PRIMARY' ]
```

`Permission denied` auf `/data/db` → Image mit passender `MONGO_UID`/`MONGO_GID` neu bauen
(`./build.sh --skip-compile`), siehe Build-README.

**Overleaf 5.5 kurz mit MongoDB 8 testen** (Login, Projekt öffnen):

```bash
docker compose up -d sharelatex
```

**FCV anheben** – danach ist ein Zurück auf MongoDB 7 nur noch über das Backup möglich:

```bash
docker compose run --rm mongo-shell --quiet --eval \
  'db.adminCommand({setFeatureCompatibilityVersion: "8.0", confirm: true})'
```

---

## Phase 3 – Redis vorbereiten

Redis enthält nur Queues und Sessions. Nach geleerten Queues kann Redis 7.4 leer starten;
das Valkey-9-Volume wird verworfen (Redis 7.4 kann Valkey-9-Dumps nicht sicher lesen).

```bash
docker compose exec sharelatex /overleaf/bin/flush-history-queues   # "project_ids":0
docker compose down                                                   # Volumes bleiben erhalten
docker volume rm ${PROJECT}_redis_data                                # gesichert in Phase 0
```

Folge: Alle Nutzer müssen sich einmal neu anmelden.

---

## Phase 4 – Overleaf CEP 6.3 mit dem neuen Compose

Repository auf den Host holen und Konfiguration übernehmen:

```bash
cd /pfad/zu/overleaf-noavx/overleaf
cp .env.example .env
cp overleaf.env.example overleaf.env
```

**`.env`:**

- `COMPOSE_PROJECT_NAME` = **alter Präfix** (`$PROJECT` aus Phase 0). Sonst legt Compose
  neue, leere Volumes an und Overleaf startet wie eine Neuinstallation.
- `MONGO_IMAGE`, `OVERLEAF_BIND` anpassen.
- Das Compose enthält keinen Reverse Proxy mehr. Lief Overleaf bisher hinter Caddy
  (Labels), den Proxy auf den veröffentlichten Port umstellen, siehe
  [`../overleaf/README.md`](../overleaf/README.md#https-über-einen-reverse-proxy-optional).
  `OVERLEAF_SITE_URL` und `OVERLEAF_SECURE_COOKIE` entsprechend übernehmen.

**`overleaf.env`:** Werte aus der alten `.env` übernehmen (`OVERLEAF_SITE_URL`, App-Name,
Template-Galerie …) und ergänzen:

```env
OVERLEAF_INVITE_TOKEN_SECRET=<openssl rand -base64 32>
OVERLEAF_FILESTORE_MIGRATION_LEVEL=2
```

**TeX Live:** Das neue Compose verwendet wieder ein Volume namens `texlive` – bei gleichem
Projektnamen also das **bestehende** `${PROJECT}_texlive`. Das alte Volume hat keinen Marker;
`texlive-init` erkennt das, leert es und kopiert den aktuellen Jahrgang hinein. Zusätzlich
setzt das Compose `PATH` auf `/usr/local/texlive/current/...`, sodass der Jahrgang nicht mehr
zum Overleaf-Image passen muss (das war beim alten Setup die Fehlerquelle). Details:
[`../overleaf/README.md`](../overleaf/README.md#tex-live).

**Starten:**

```bash
docker volume ls | grep "^local *${PROJECT}_"     # mongo_data und sharelatex_data müssen auftauchen
docker compose pull                                # TeX Live ~5 GB, dauert
docker compose up -d
docker compose logs -f texlive-init                # kopiert TeX Live ins Volume, einige Minuten
docker compose logs -f sharelatex
```

Beim ersten Start laufen die Datenbank-Migrationen von 5.5 auf 6.3; das dauert einige Minuten.
`mongo-shell` meldet „Replica Set bereits initialisiert“ und „Replica Set bereit“ – das
Replica Set wird aus dem bestehenden Volume übernommen. Hat das alte Compose einen
gleichnamigen `mongo-shell`-Service (z. B. mit `sleep infinity`), ersetzt ihn der neue.

**Prüfen:** Login, bestehendes Projekt öffnen, Bilder sichtbar, kompilieren (auch ein
KOMA-Script-Brief mit `scrlttr2`), History öffnen, Einladung an einen zweiten Nutzer.

---

## Phase 5 – Aufräumen (nach einigen Tagen ohne Probleme)

```bash
docker compose run --rm --entrypoint rm sharelatex -rf /var/lib/overleaf/data/old_user_files
```

Backups aus Phase 0 noch eine Weile aufheben.

---

## Rollback

Vor Phase 4: altes Compose aus `backup/` wiederherstellen und das MongoDB-Volume aus dem Backup
zurückspielen (MongoDB 7 kann FCV 8.0 nicht öffnen).

Nach Phase 4: alle drei Volumes aus dem Backup zurückspielen und altes Compose verwenden:

```bash
docker compose down
for v in mongo_data sharelatex_data redis_data; do
  docker volume rm ${PROJECT}_${v}; docker volume create ${PROJECT}_${v}
  docker run --rm -v ${PROJECT}_${v}:/data -v "$PWD/backup":/backup alpine \
    tar xzf /backup/${v}-pre-v6-<DATUM>.tgz -C /data
done
```

## Quellen

- [Overleaf: Binary files migration](https://docs.overleaf.com/on-premises/release-notes/release-notes-5.x.x/binary-files-migration)
- [Overleaf: Release Notes 6.x.x](https://docs.overleaf.com/on-premises/release-notes/release-notes-6.x.x)
- [Overleaf CE+ Wiki und Release Notes](https://github.com/yu-i-i/overleaf-cep/wiki)
