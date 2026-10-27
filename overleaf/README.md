# Overleaf CEP 6.x – Neuinstallation mit Docker Compose

Setup für [Overleaf Extended Community Edition (CEP)](https://github.com/yu-i-i/overleaf-cep)
mit MongoDB 8 ohne AVX, Redis 7.4 und [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)
als HTTPS-Reverse-Proxy.

Für ein **Upgrade einer bestehenden 5.5-Installation** gilt stattdessen
[`../docs/migration-5.5-to-6.3.md`](../docs/migration-5.5-to-6.3.md).

## Dateien

| Datei | Zweck |
|---|---|
| `docker-compose.yml` | Redis, MongoDB, Replica-Set-Init, Overleaf, mongosh-Werkzeug |
| `docker-compose.sandbox.yml` | Optional: Sandboxed Compiles mit vollem TeX Live |
| `.env.example` | Compose-Variablen: Images, Hostname, Projektname |
| `overleaf.env.example` | Overleaf-Konfiguration inkl. Secrets |

## Voraussetzungen

- MongoDB-Image ohne AVX gebaut und auf dem Host geladen, siehe [`../mongodb-noavx`](../mongodb-noavx)
  (bei CPU mit AVX stattdessen `MONGO_IMAGE=mongo:8.0`)
- caddy-docker-proxy läuft, sein Netzwerk existiert (`docker network ls`)
- DNS-Eintrag für den Hostnamen zeigt auf den Host

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
docker compose up -d
docker compose logs -f sharelatex      # erster Start: Migrationen, einige Minuten
```

Die Startreihenfolge erzwingt Compose: `mongo` (healthy) → `mongo-init` (Replica Set) →
`redis` (healthy) → `sharelatex`.

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

## LaTeX-Pakete

Das Overleaf-Image bringt nur ein minimales TeX Live mit; Klassen wie `scrlttr2`
(KOMA-Script) fehlen. Zwei Wege:

**Sandboxed Compiles (empfohlen, nur CEP)** – jedes Projekt kompiliert in einem
`texlive/texlive`-Container mit vollem TeX Live:

```bash
docker pull texlive/texlive:latest-full
# .env:          OVERLEAF_DATA_DIR=/srv/overleaf   (absoluter Host-Pfad, wird Datenverzeichnis)
# overleaf.env:  ALL_TEX_LIVE_DOCKER_IMAGES / TEX_LIVE_DOCKER_IMAGE einkommentieren
docker compose -f docker-compose.yml -f docker-compose.sandbox.yml up -d
```

Der Override ersetzt das Named Volume durch einen Bind-Mount, weil die Compile-Container
vom Docker-Daemon des Hosts gestartet werden und einen Host-Pfad brauchen. Bei einer
bestehenden Installation die Daten vorher aus dem Volume dorthin kopieren.
Sicherheitshinweis: Overleaf erhält Zugriff auf den Docker-Socket.

**Eigenes Image mit Zusatzpaketen** – ohne Docker-Socket:

```dockerfile
FROM overleafcep/sharelatex:6.3.0-ext-v5.1
RUN tlmgr install koma-script babel-german hyphen-german
```

Meldet `tlmgr` „Remote repository is newer than local“, vorher das historische Repository
des installierten TeX-Live-Jahrgangs setzen
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
