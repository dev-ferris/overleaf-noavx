# Overleaf CEP 6.x – Neuinstallation mit Docker Compose

Setup für [Overleaf Extended Community Edition (CEP)](https://github.com/yu-i-i/overleaf-cep)
mit MongoDB 8 ohne AVX, Redis 7.4, **vollständigem TeX Live** (per Volume, ohne Docker-Socket) und
[caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) als HTTPS-Reverse-Proxy.

Für ein **Upgrade einer bestehenden 5.5-Installation** gilt stattdessen
[`../docs/migration-5.5-to-6.3.md`](../docs/migration-5.5-to-6.3.md).

## Dateien

| Datei | Zweck |
|---|---|
| `docker-compose.yml` | Redis, MongoDB, Replica-Set-Init, TeX-Live-Volume, Overleaf, mongosh-Werkzeug |
| `.env.example` | Compose-Variablen: Images, Hostname, Projektname |
| `overleaf.env.example` | Overleaf-Konfiguration inkl. Secrets |

## Voraussetzungen

- MongoDB-Image ohne AVX: Standard ist [`devferris/mongodb-no-avx:8.0.17-nehalem`](https://hub.docker.com/r/devferris/mongodb-no-avx)
  von Docker Hub (wird beim ersten `up` gezogen). Eigenbau siehe [`../mongodb-noavx`](../mongodb-noavx),
  bei CPU mit AVX stattdessen `MONGO_IMAGE=mongo:8.0`
- caddy-docker-proxy läuft, sein Netzwerk existiert (`docker network ls`)
- DNS-Eintrag für den Hostnamen zeigt auf den Host
- Rund 15 GB freier Platz für TeX Live (Image ~5 GB komprimiert + Volume ~8 GB)

## Einrichtung

```bash
cp .env.example .env
cp overleaf.env.example overleaf.env
openssl rand -base64 32        # -> OVERLEAF_INVITE_TOKEN_SECRET in overleaf.env
```

In `.env` anpassen: `OVERLEAF_HOSTNAME`, `CADDY_NETWORK`, `MONGO_IMAGE`.
In `overleaf.env` anpassen: `OVERLEAF_SITE_URL` (identisch zum Hostnamen),
`OVERLEAF_INVITE_TOKEN_SECRET`, `OVERLEAF_ADMIN_EMAIL`.

```bash
docker compose pull                    # TeX Live ~5 GB, dauert
docker compose up -d
docker compose logs -f texlive-init    # erster Start: kopiert TeX Live ins Volume, einige Minuten
docker compose logs -f sharelatex      # danach: Migrationen, einige Minuten
```

Die Startreihenfolge erzwingt Compose: `mongo` (healthy) → `mongo-init` (Replica Set) →
`redis` (healthy) → `texlive-init` (TeX Live im Volume) → `sharelatex`.

### Ersten Administrator anlegen

Im Browser `https://<hostname>/launchpad` öffnen und Konto anlegen – die Seite gibt es nur,
solange noch kein Admin existiert. Alternativ:

```bash
docker compose exec sharelatex bash -c \
  "cd /overleaf/services/web && node modules/server-ce-scripts/scripts/create-user.mjs --admin --email=du@example.com"
```

Das Skript gibt einen Link zum Setzen des Passworts aus. Weitere Nutzer unter *Admin → Manage Users*.

## Ohne Reverse Proxy (nur zum Testen)

Im Compose bei `sharelatex` die Caddy-Labels und das Netzwerk `caddy` entfernen und
`ports: ["8088:80"]` ergänzen. In `overleaf.env`:

```env
OVERLEAF_SITE_URL=http://overleaf-host.example.com:8088
# OVERLEAF_SECURE_COOKIE=true      <- auskommentieren, nicht auf false setzen!
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

**Backup** (konsistent im gestoppten Zustand):

```bash
docker compose stop sharelatex
PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)
mkdir -p backup
for v in mongo_data sharelatex_data redis_data; do
  docker run --rm -v ${PROJECT}_${v}:/data:ro -v "$PWD/backup":/backup alpine \
    tar czf /backup/${v}-$(date +%F).tgz -C /data .
done
cp .env overleaf.env backup/
docker compose start sharelatex
```

`overleaf.env` gehört ins Backup: Ohne das alte `OVERLEAF_INVITE_TOKEN_SECRET` werden offene
Einladungen ungültig.

Bei Problemen: [`../docs/troubleshooting.md`](../docs/troubleshooting.md).
