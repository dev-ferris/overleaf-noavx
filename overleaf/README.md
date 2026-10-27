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
| `docker-compose.yml` | Redis, MongoDB, Replica-Set-Init, TeX-Live-Volume, Overleaf, Backup, mongosh-Werkzeug |
| `.env.example` | Compose-Variablen: Images, Port, Projektname, Backup-Zeitplan |
| `overleaf.env.example` | Overleaf-Konfiguration inkl. Secrets |

## Voraussetzungen

- MongoDB-Image ohne AVX: Standard ist [`devferris/mongodb-no-avx:8.0.17-nehalem`](https://hub.docker.com/r/devferris/mongodb-no-avx)
  von Docker Hub (wird beim ersten `up` gezogen). Eigenbau siehe [`../mongodb-noavx`](../mongodb-noavx),
  bei CPU mit AVX stattdessen `MONGO_IMAGE=mongo:8.0`
- Rund 15 GB freier Platz für TeX Live (Image ~5 GB komprimiert + Volume ~8 GB)

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
docker compose pull                    # TeX Live ~5 GB, dauert
docker compose up -d
docker compose logs -f texlive-init    # erster Start: kopiert TeX Live ins Volume, einige Minuten
docker compose logs -f sharelatex      # danach: Migrationen, einige Minuten
```

Die Startreihenfolge erzwingt Compose: `mongo` (healthy) → `mongo-init` (Replica Set mit
Primary, healthy) → `redis` (healthy) → `texlive-init` (TeX Live im Volume) → `sharelatex`.
`mongo-init` läuft danach weiter, weil das Backup darin `mongodump` ausführt.

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
2. Läuft der Proxy auf demselben Host: `OVERLEAF_BIND=127.0.0.1:8088` in `.env`, damit Overleaf
   nicht zusätzlich unverschlüsselt im Netz erreichbar ist.
3. In `overleaf.env`:

```env
OVERLEAF_SITE_URL=https://overleaf.example.home
OVERLEAF_SECURE_COOKIE=true
```

Danach `docker compose up -d --force-recreate sharelatex`.

Beispiel Caddyfile:

```caddyfile
overleaf.example.home {
    reverse_proxy 127.0.0.1:8088
}
```

## TeX Live

Das Overleaf-Image selbst enthält nur ein minimales TeX Live (`scheme-basic`); Klassen wie
`scrlttr2` (KOMA-Script) fehlen dort. Dieses Setup ersetzt es durch das **vollständige**
TeX Live aus [`texlive/texlive:latest-full`](https://hub.docker.com/r/texlive/texlive) – alle
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
`docker image rm texlive/texlive:latest-full` gibt ~5 GB frei; das nächste `docker compose up`
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
docker compose run --rm mongo-shell                                   # interaktiv
docker compose run --rm mongo-shell --quiet --eval 'rs.status().members.map(m => m.stateStr)'
```

**Admins anzeigen / setzen / entziehen:**

```bash
docker compose run --rm mongo-shell --quiet --eval \
  'db.getSiblingDB("sharelatex").users.find({isAdmin: true}, {email: 1}).toArray()'
docker compose run --rm mongo-shell --quiet --eval \
  'db.getSiblingDB("sharelatex").users.updateOne({email: "du@example.com"}, {$set: {isAdmin: true}})'
```

## Backup

Der Service `backup` ([offen/docker-volume-backup](https://github.com/offen/docker-volume-backup))
sichert täglich um 03:00 (`BACKUP_CRON`, Zeitzone `TZ`) nach `./backup` (`BACKUP_DIR`) und löscht
Archive älter als 14 Tage (`BACKUP_RETENTION_DAYS`).

**Ablauf eines Laufs:**

1. `archive-pre` im Container `mongo-init`: `mongodump --oplog --gzip` nach Volume `mongo_dump` –
   bei laufender Datenbank, `--oplog` macht den Dump trotzdem konsistent
2. `sharelatex` und `redis` werden gestoppt (Label `docker-volume-backup.stop-during-backup`)
3. Archiv `overleaf-<zeitstempel>.tar.gz` aus `mongo_dump`, `sharelatex_data`, `redis_data`,
   `overleaf.env` und `.env`
4. `sharelatex` und `redis` starten wieder (Ausfall: Dauer des Archivierens, meist Sekunden bis Minuten)
5. `archive-post`: Dump im Volume `mongo_dump` löschen

Nicht gesichert werden `mongo_data` (Rohdateien einer laufenden DB sind kein verlässliches
Backup – dafür gibt es den Dump) und `texlive` (jederzeit aus dem Image reproduzierbar).
`overleaf.env` ist enthalten, weil ohne das alte `OVERLEAF_INVITE_TOKEN_SECRET` offene
Einladungen ungültig werden.

**Sofort sichern** (z. B. vor einem Update):

```bash
docker compose exec backup backup
ls -lh backup/
```

**Mehrere offen-Instanzen auf dem Host:** `BACKUP_LABEL` je Instanz eindeutig wählen. Labels
und `EXEC_LABEL` hängen daran; mit gleichem Wert würden sich Instanzen gegenseitig Container
stoppen oder Dumps auslösen.

**Docker-Socket:** Der Backup-Container braucht ihn (nur lesend), um Container zu stoppen und
`mongodump` per `docker exec` auszuführen. Overleaf selbst hat keinen Zugriff darauf.

### Wiederherstellen

Gilt für dieselbe Installation ebenso wie für einen neuen Host (dort zuerst Repository und
Images bereitstellen).

```bash
cd overleaf
ARCHIV=backup/overleaf-<zeitstempel>.tar.gz
PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)

# 1. Archiv entpacken (Inhalt liegt unter backup/<volume>/ bzw. backup/config/)
rm -rf restore && mkdir restore && tar -xzf "$ARCHIV" -C restore
ls restore/backup

# 2. Konfiguration: bei neuem Host übernehmen, sonst nur vergleichen
cp -n restore/backup/config/overleaf.env overleaf.env
cp -n restore/backup/config/compose.env .env

# 3. Nur MongoDB + Replica Set starten, Overleaf und Redis bleiben aus
docker compose up -d mongo mongo-init
docker compose stop sharelatex redis 2>/dev/null || true

# 4. sharelatex_data und redis_data zurückspielen (Inhalt wird ersetzt!)
for v in sharelatex_data redis_data; do
  docker volume create ${PROJECT}_${v} >/dev/null
  docker run --rm -v ${PROJECT}_${v}:/data -v "$PWD/restore/backup/$v":/src:ro alpine \
    sh -c 'find /data -mindepth 1 -delete && cp -a /src/. /data/'
done

# 5. MongoDB aus dem Dump wiederherstellen (--drop ersetzt vorhandene Collections)
docker compose cp restore/backup/mongo_dump/mongo.archive.gz mongo-init:/dump/mongo.archive.gz
docker compose exec mongo-init mongorestore --uri="mongodb://mongo:27017/?directConnection=true" \
  --oplogReplay --drop --gzip --archive=/dump/mongo.archive.gz
docker compose exec mongo-init sh -c 'rm -f /dump/*'

# 6. Alles starten
docker compose up -d
rm -rf restore
```

Danach prüfen: Login, Projekte vorhanden, Bilder sichtbar, Kompilieren. Das `texlive`-Volume
wird bei Bedarf automatisch neu befüllt.

Bei Problemen: [`../docs/troubleshooting.md`](../docs/troubleshooting.md).
