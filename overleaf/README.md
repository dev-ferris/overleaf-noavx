# Overleaf CEP 6.x – Neuinstallation mit Docker Compose

Setup für [Overleaf Extended Community Edition (CEP)](https://github.com/yu-i-i/overleaf-cep)
mit MongoDB 8 ohne AVX, Redis 7.4, **vollständigem TeX Live** über Sandboxed Compiles und
[caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) als HTTPS-Reverse-Proxy.

Für ein **Upgrade einer bestehenden 5.5-Installation** gilt stattdessen
[`../docs/migration-5.5-to-6.3.md`](../docs/migration-5.5-to-6.3.md).

## Dateien

| Datei | Zweck |
|---|---|
| `docker-compose.yml` | Redis, MongoDB, Replica-Set-Init, TeX Live, Overleaf, mongosh-Werkzeug |
| `.env.example` | Compose-Variablen: Images, Hostname, Projektname, Host-Datenpfad |
| `overleaf.env.example` | Overleaf-Konfiguration inkl. Secrets |

## Voraussetzungen

- MongoDB-Image ohne AVX: Standard ist [`devferris/mongodb-no-avx:8.0.17-nehalem`](https://hub.docker.com/r/devferris/mongodb-no-avx)
  von Docker Hub (wird beim ersten `up` gezogen). Eigenbau siehe [`../mongodb-noavx`](../mongodb-noavx),
  bei CPU mit AVX stattdessen `MONGO_IMAGE=mongo:8.0`
- caddy-docker-proxy läuft, sein Netzwerk existiert (`docker network ls`)
- DNS-Eintrag für den Hostnamen zeigt auf den Host
- Rund 10 GB freier Platz für das TeX-Live-Image

## Einrichtung

```bash
cp .env.example .env
cp overleaf.env.example overleaf.env
openssl rand -base64 32        # -> OVERLEAF_INVITE_TOKEN_SECRET in overleaf.env
```

In `.env` anpassen: `OVERLEAF_HOSTNAME`, `CADDY_NETWORK`, `MONGO_IMAGE`.
In `overleaf.env` anpassen: `OVERLEAF_SITE_URL` (identisch zum Hostnamen),
`OVERLEAF_INVITE_TOKEN_SECRET`, `OVERLEAF_ADMIN_EMAIL`.

**Host-Pfad des Datenvolumes prüfen** – wichtig für TeX Live, siehe unten:

```bash
docker compose up --no-start           # legt Volumes an, zieht Images (TeX Live ~5 GB)
docker volume inspect -f '{{.Mountpoint}}' "$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)_sharelatex_data"
```

Die Ausgabe muss mit `OVERLEAF_HOST_DATA_DIR` in `.env` übereinstimmen; sonst anpassen.

```bash
docker compose up -d
docker compose logs -f sharelatex      # erster Start: Migrationen, einige Minuten
```

Die Startreihenfolge erzwingt Compose: `mongo` (healthy) → `mongo-init` (Replica Set) →
`redis` (healthy) → `texlive` (Image vorhanden) → `sharelatex`.

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

Das Overleaf-Image selbst enthält nur ein minimales TeX Live; Klassen wie `scrlttr2`
(KOMA-Script) fehlen dort. Dieses Setup nutzt deshalb **Sandboxed Compiles** der CEP:
Jedes Projekt kompiliert in einem eigenen Container aus `texlive/texlive:latest-full` mit
vollständigem TeX Live – alle CTAN-Pakete, `latexmk`, `biber`, `xindy` usw.

So greifen die Teile ineinander:

| Teil | Aufgabe |
|---|---|
| Service `texlive` | Lädt das TeX-Live-Image beim `up`/`pull`, beendet sich sofort |
| `DOCKER_RUNNER`, `SANDBOXED_COMPILES` | Schalten in Overleaf die Container-Kompilierung ein |
| `ALL_TEX_LIVE_DOCKER_IMAGES`, `TEX_LIVE_DOCKER_IMAGE` | Verfügbare Images und Standard für neue Projekte (aus `TEXLIVE_IMAGE`) |
| `/var/run/docker.sock` | Overleaf startet die Compile-Container über den Docker-Daemon des Hosts |
| `SANDBOXED_COMPILES_HOST_DIR_*` | Host-Pfade von `compiles/`, `output/`, `cache/` – der Host-Daemon mountet sie in die Compile-Container |

Die Host-Pfade sind der Grund, warum `OVERLEAF_HOST_DATA_DIR` stimmen muss: Die
Compile-Container entstehen außerhalb von Overleaf und sehen nur Host-Pfade.

**Jahrgang wechseln oder mehrere anbieten:** `TEXLIVE_IMAGE` in `.env` ändern, z. B. auf
`texlive/texlive:TL2025-historic`. Mehrere Images zur Auswahl pro Projekt (Projektmenü →
*TeX Live version*) über eine kommagetrennte Liste in `ALL_TEX_LIVE_DOCKER_IMAGES` im Compose;
jedes davon vorher mit `docker pull` laden.

**`-shell-escape`** (z. B. für `minted`): `TEX_COMPILER_EXTRA_FLAGS=-shell-escape` in
`overleaf.env`. In der Sandbox vertretbar, da der Code im Compile-Container läuft.

**Sicherheit:** Zugriff auf den Docker-Socket entspricht Root-Rechten auf dem Host. Overleaf CE
ist ohnehin nur für vertrauenswürdige Nutzer gedacht; in diesem Rahmen ist das üblich.

### Alternative ohne Docker-Socket

Wer den Socket nicht freigeben will: Sandbox-Teile (Service `texlive`, die
`SANDBOXED_*`/`DOCKER_RUNNER`/`*TEX_LIVE*`-Variablen und den Socket-Mount) entfernen und
stattdessen ein eigenes Overleaf-Image mit Zusatzpaketen bauen:

```dockerfile
FROM overleafcep/sharelatex:6.3.0-ext-v5.1
RUN tlmgr install koma-script babel-german hyphen-german
# oder alles: RUN tlmgr install scheme-full   (+5–7 GB, langer Build)
```

Meldet `tlmgr` „Remote repository is newer than local“, vorher das historische Repository
des installierten Jahrgangs setzen
(`tlmgr option repository https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/<jahr>/tlnet-final`).

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
