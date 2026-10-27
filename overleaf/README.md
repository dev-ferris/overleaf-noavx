# Overleaf CEP 6.x – Neuinstallation mit Docker Compose

Setup für [Overleaf Extended Community Edition (CEP)](https://github.com/yu-i-i/overleaf-cep)
mit MongoDB 8 ohne AVX, Redis 7.4 und **vollständigem TeX Live** (per Volume, ohne Docker-Socket).
Overleaf ist direkt über HTTP auf einem Port erreichbar; ein Reverse Proxy für HTTPS ist optional
und nicht Teil des Compose.

Für ein **Upgrade einer bestehenden 5.5-Installation** gilt stattdessen
[`../docs/migration-5.5-to-6.3.md`](../docs/migration-5.5-to-6.3.md).

## Dateien

| Datei | Zweck |
|---|---|
| `docker-compose.yml` | Redis, MongoDB, `mongo-shell` (Replica-Set-Init + Shell), TeX-Live-Volume, Overleaf |
| `.env.example` | Compose-Variablen: Images, Port, Projektname |
| `overleaf.env.example` | Overleaf-Konfiguration inkl. Secrets |

## Voraussetzungen

- MongoDB-Image ohne AVX: Standard ist [`devferris/mongodb-no-avx:8.0.17-nehalem`](https://hub.docker.com/r/devferris/mongodb-no-avx)
  von Docker Hub (wird beim ersten `up` gezogen). Eigenbau siehe [`../mongodb-noavx`](../mongodb-noavx),
  bei CPU mit AVX stattdessen `MONGO_IMAGE=mongo:8.0`
- Rund 15 GB freier Platz für TeX Live: das Image und seine Kopie im Volume belegen jeweils mehrere GB

## Einrichtung

```bash
cp .env.example .env
cp overleaf.env.example overleaf.env
openssl rand -base64 32        # -> OVERLEAF_INVITE_TOKEN_SECRET in overleaf.env
```

In `.env` anpassen: `OVERLEAF_BIND` (Port, Standard 8088), `MONGO_IMAGE`.
In `overleaf.env` anpassen: `OVERLEAF_SITE_URL` (exakt die Adresse im Browser, inkl. Port),
`OVERLEAF_INVITE_TOKEN_SECRET`, `OVERLEAF_ADMIN_EMAIL`.

```bash
docker compose pull                    # TeX-Live-Image: mehrere GB, dauert
docker compose up -d
docker compose logs -f texlive-init    # erster Start: kopiert TeX Live ins Volume, einige Minuten
docker compose logs -f sharelatex      # danach: Migrationen, einige Minuten
```

Die Startreihenfolge erzwingt Compose: `mongo` (healthy) → `mongo-shell` (Replica Set mit
Primary, healthy) → `redis` (healthy) → `texlive-init` (TeX Live im Volume) → `sharelatex`.
`mongo-shell` läuft danach weiter und dient als MongoDB-Shell (`docker compose exec mongo-shell mongosh ...`).

### Ersten Administrator anlegen

Im Browser `http://<host>:8088/launchpad` öffnen und Konto anlegen – die Seite gibt es nur,
solange noch kein Admin existiert. Alternativ:

```bash
docker compose exec sharelatex bash -c \
  "cd /overleaf/services/web && node modules/server-ce-scripts/scripts/create-user.mjs --admin --email=du@example.com"
```

Das Skript gibt einen Link zum Setzen des Passworts aus. Weitere Nutzer unter *Admin → Manage Users*.

## HTTPS über einen Reverse Proxy (optional)

Das Compose veröffentlicht nur HTTP auf `OVERLEAF_BIND`. Für HTTPS einen beliebigen Reverse
Proxy (Caddy, Traefik, nginx …) davorsetzen:

1. Proxy auf `http://<host>:8088` weiterleiten lassen. **WebSockets** müssen durchgereicht
   werden (Echtzeit-Editor); bei Caddy und Traefik passiert das automatisch, bei nginx
   `proxy_set_header Upgrade` / `Connection "upgrade"` setzen.
2. Läuft der Proxy direkt auf demselben Host: `OVERLEAF_BIND=127.0.0.1:8088` in `.env`, damit
   Overleaf nicht zusätzlich unverschlüsselt im Netz erreichbar ist. Läuft der Proxy selbst in
   einem Container, erreicht er `127.0.0.1` des Hosts nicht – dann die LAN-IP des Hosts verwenden.
3. In `overleaf.env`:

```env
OVERLEAF_SITE_URL=https://overleaf.example.com
OVERLEAF_SECURE_COOKIE=true
```

Danach `docker compose up -d --force-recreate sharelatex`.

Beispiel Caddyfile:

```caddyfile
overleaf.example.com {
    reverse_proxy 127.0.0.1:8088
}
```

## TeX Live

Das Overleaf-Image selbst enthält nur ein minimales TeX Live (`scheme-basic`); Klassen wie
`scrlttr2` (KOMA-Script) fehlen dort. Dieses Setup ersetzt es durch das **vollständige**
TeX Live aus [`texlive/texlive:latest`](https://hub.docker.com/r/texlive/texlive) – alle
CTAN-Pakete, `latexmk`, `biber`, `xindy` usw. – eingebunden als Volume, ohne Docker-Socket.

| Teil | Aufgabe |
|---|---|
| Service `texlive-init` | Kopiert `/usr/local/texlive` aus dem TeX-Live-Image ins Volume `texlive`, legt den Link `current` → Jahrgang an, prüft `latexmk`/`pdflatex`, beendet sich |
| Volume `texlive` → `/usr/local/texlive:ro` | Ersetzt im Overleaf-Container das minimale TeX Live |
| `PATH` im Service `sharelatex` | `/usr/local/texlive/current/bin/x86_64-linux` steht vorn; Overleaf ruft `latexmk` über den `PATH` auf |

**Warum der `current`-Link und `PATH`:** Das Overleaf-Image verlinkt seine TeX-Binaries in
`/usr/local/bin` auf einen festen Jahrgang (`/usr/local/texlive/<jahr>/...`). Stammt das Volume
aus einem anderen Jahrgang, liefen diese Links ins Leere. Über `current` und `PATH` ist der
Jahrgang des Overleaf-Images egal.

**Aktualisieren / Jahrgang wechseln:** `TEXLIVE_IMAGE` in `.env` ändern oder neueres Image
ziehen, dann:

```bash
docker compose pull texlive-init
docker compose stop sharelatex         # nicht während des Kopierens kompilieren
docker compose up -d
```

`texlive-init` erkennt die Änderung (Marker aus Jahrgang und Prüfsumme der Paketdatenbank)
und kopiert neu, danach startet `sharelatex`. Ohne Änderung ist `texlive-init` nach Sekunden
fertig und lässt das Volume unangetastet – ein normales `docker compose up -d` ist also
jederzeit unkritisch.

**Prüfen, welches TeX Live Overleaf verwendet:**

```bash
docker compose exec sharelatex bash -c 'which latexmk; pdflatex --version | head -1; kpsewhich scrlttr2.cls'
```

**Platz sparen:** Nach dem Kopieren wird das Image nur noch für Updates gebraucht.
`docker image rm texlive/texlive:latest` gibt mehrere GB frei; das nächste `docker compose up`
zieht es dann allerdings erneut.

**`-shell-escape`** (z. B. für `minted`): `TEX_COMPILER_EXTRA_FLAGS=-shell-escape` in
`overleaf.env`. Ohne Sandbox laufen die Befehle direkt im Overleaf-Container – nur mit
vertrauenswürdigen Nutzern.

### Alternative: Sandboxed Compiles

Die CEP kann jedes Projekt auch in einem eigenen TeX-Live-Container kompilieren (pro Projekt
wählbarer Jahrgang, Isolation). Das erfordert allerdings den Docker-Socket im
Overleaf-Container, also faktisch Root-Rechte auf dem Host, und wird hier deshalb nicht
verwendet. Siehe [CEP-Wiki: Sandboxed Compiles](https://github.com/yu-i-i/overleaf-cep/wiki/Extended-CE:-Sandboxed-Compiles).

## Betrieb

**MongoDB-Shell:**

```bash
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true"   # interaktiv
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval 'rs.status().members.map(m => m.stateStr)'
```

**Admins anzeigen / setzen / entziehen:**

```bash
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval \
  'db.getSiblingDB("sharelatex").users.find({isAdmin: true}, {email: 1}).toArray()'
docker compose exec mongo-shell mongosh "mongodb://mongo:27017/?directConnection=true" --quiet --eval \
  'db.getSiblingDB("sharelatex").users.updateOne({email: "du@example.com"}, {$set: {isAdmin: true}})'
```

## Backup

Konsistent sichern: MongoDB per `mongodump` (läuft bei laufender Datenbank, `--oplog` sorgt
für einen konsistenten Stand), `sharelatex_data` bei gestopptem Overleaf. Nicht gesichert
werden `mongo_data` (Rohdateien einer laufenden DB sind kein verlässliches Backup) und
`texlive` (jederzeit aus dem Image reproduzierbar).

Im Verzeichnis `overleaf/` ausführen:

```bash
PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)
ZIEL=backup/$(date +%F_%H%M) && mkdir -p "$ZIEL"

# MongoDB
docker compose exec mongo-shell mongodump --quiet \
  --uri="mongodb://mongo:27017/?directConnection=true" --oplog --gzip --archive=/tmp/mongo.archive.gz
docker compose cp mongo-shell:/tmp/mongo.archive.gz "$ZIEL/"
docker compose exec mongo-shell rm -f /tmp/mongo.archive.gz

# Overleaf-Dateien und Redis
docker compose stop sharelatex redis
for v in sharelatex_data redis_data; do
  docker run --rm -v ${PROJECT}_${v}:/data:ro -v "$PWD/$ZIEL":/backup alpine \
    tar czf /backup/${v}.tgz -C /data .
done
docker compose start redis sharelatex

# Konfiguration (enthält OVERLEAF_INVITE_TOKEN_SECRET)
cp .env overleaf.env "$ZIEL/"
```

Für regelmäßige Backups lässt sich das als Skript per Cron ausführen. Da `mongo-shell`
dauerhaft läuft, kann ein Backup-Werkzeug `mongodump` auch per `docker exec` darin auslösen.

### Wiederherstellen

Im Verzeichnis `overleaf/` ausführen. Auf einem neuen Host zuerst die Konfiguration aus dem
Backup übernehmen (`cp backup/<zeitstempel>/{.env,overleaf.env} .`) – sie enthält Projektname
und `OVERLEAF_INVITE_TOKEN_SECRET`.

```bash
QUELLE=backup/<zeitstempel>
PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)

docker compose up -d mongo mongo-shell          # MongoDB + Replica Set
docker compose stop sharelatex redis 2>/dev/null || true

# Overleaf-Dateien und Redis (Inhalt wird ersetzt!)
for v in sharelatex_data redis_data; do
  docker volume create ${PROJECT}_${v} >/dev/null
  docker run --rm -v ${PROJECT}_${v}:/data -v "$PWD/$QUELLE":/backup:ro alpine \
    sh -c 'find /data -mindepth 1 -delete && tar xzf /backup/'${v}'.tgz -C /data'
done

# MongoDB (--drop ersetzt vorhandene Collections)
docker compose cp "$QUELLE/mongo.archive.gz" mongo-shell:/tmp/mongo.archive.gz
docker compose exec mongo-shell mongorestore --uri="mongodb://mongo:27017/?directConnection=true" \
  --oplogReplay --drop --gzip --archive=/tmp/mongo.archive.gz
docker compose exec mongo-shell rm -f /tmp/mongo.archive.gz

docker compose up -d
```

Bei Problemen: [`../docs/troubleshooting.md`](../docs/troubleshooting.md).
