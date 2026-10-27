# Troubleshooting

Probleme, die beim Aufsetzen tatsächlich aufgetreten sind, mit Ursache und Lösung.

## Overleaf

### „Session error. Please check you have cookies enabled.“

**Ursache:** Secure-Cookies bei Zugriff über HTTP. Overleaf wertet `OVERLEAF_SECURE_COOKIE`
nur auf *gesetzt* aus (`process.env.OVERLEAF_SECURE_COOKIE != null`) –
`OVERLEAF_SECURE_COOKIE=false` schaltet Secure-Cookies also **ein**. Der Browser verwirft das
Cookie über HTTP, der Login scheitert an der CSRF-Prüfung.

**Lösung:** Bei HTTP-Zugriff die Zeile entfernen bzw. auskommentieren, nur bei HTTPS setzen.
`OVERLEAF_SITE_URL` muss exakt der Adresse im Browser entsprechen (inkl. Port).
Änderungen an Env-Dateien erfordern `docker compose up -d --force-recreate sharelatex`,
ein `restart` reicht nicht.

### „Missing required secrets: OVERLEAF_INVITE_TOKEN_SECRET“, Container startet in Schleife

Seit 6.2 Pflicht. `openssl rand -base64 32` einmal erzeugen, in `overleaf.env` eintragen und
nie mehr ändern (sonst werden offene Einladungen ungültig). Nicht dynamisch im Compose erzeugen.

### `LaTeX Error: File 'scrlttr2.cls' not found`

Das Overleaf-Image enthält nur ein minimales TeX Live ohne KOMA-Script.
Lösungen siehe [`../overleaf/README.md`](../overleaf/README.md#latex-pakete).
`tlmgr install` im laufenden Container ist nicht dauerhaft – beim Neuerstellen ist das Paket weg.

### `pdflatex` nicht gefunden nach Upgrade

Ein eingebundenes TeX-Live-Volume (`/usr/local/texlive`) passt nicht zum Jahrgang des neuen
Images. Die Symlinks in `/usr/local/bin` zeigen ins Leere. Volume entfernen oder zum Jahrgang
passend neu befüllen:

```bash
docker run --rm --entrypoint ls <overleaf-image> /usr/local/texlive
```

### Overleaf hängt beim Start, Log zeigt Mongo-Timeouts

Meist ist das Replica Set nicht initialisiert oder mit falschem Hostnamen eingetragen
(Container-ID statt `mongo:27017`):

```bash
docker compose run --rm mongo-shell --quiet --eval 'rs.conf().members.map(m => m.host)'
```

Falschen Host korrigieren:

```bash
docker compose run --rm mongo-shell --quiet --eval \
  'c = rs.conf(); c.members[0].host = "mongo:27017"; rs.reconfig(c, {force: true})'
```

### `rs.initiate(...)`: „bash: syntax error near unexpected token“

Der Befehl ist JavaScript und gehört in `mongosh`, nicht in die Bash des Containers.
Das no-AVX-Image enthält kein mongosh – über den `mongo-shell`-Service ausführen:

```bash
docker compose run --rm mongo-shell --quiet --eval \
  'rs.initiate({_id: "rs0", members: [{_id: 0, host: "mongo:27017"}]})'
```

### Caddy erreicht den Container nicht (502)

Hängt `sharelatex` in mehreren Netzwerken, muss caddy-docker-proxy wissen, welches es nehmen
soll: Label `caddy_ingress_network` (im Compose gesetzt) oder `CADDY_INGRESS_NETWORKS` am
Caddy-Container. Prüfen mit `docker logs <caddy-container>`.

### `user_files` existiert nach der Binary-File-Migration nicht mehr

Erwartet: Schritt 5 benennt es in `old_user_files` um; mit Stufe 2 liegen die Dateien in der
History. Existierte nie ein `user_files`, wurden nie Binärdateien hochgeladen.

```bash
docker compose run --rm --entrypoint ls sharelatex -la /var/lib/overleaf/data/
```

## MongoDB

### `Illegal instruction` / Exit-Code 132

Die CPU kann Befehle nicht, die im Binary stecken: entweder offizielles MongoDB ≥ 5.0 auf einer
CPU ohne AVX, oder der Eigenbau hat ein zu modernes `CPU_ARCH`. Mit `CPU_ARCH=core2` neu bauen.

### `Permission denied` auf `/data/db`

UID des `mongodb`-Users im neuen Image passt nicht zum Besitzer des bestehenden Volumes.
UID im alten Image ermitteln und neu bauen (dauert nur Minuten):

```bash
docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28
MONGO_UID=<uid> MONGO_GID=<gid> ./build.sh --skip-compile --save
```

### Startwarnungen im MongoDB-Log

| Warnung | Bewertung |
|---|---|
| `glibc support for rseq ... GLIBC_TUNABLES=glibc.pthread.rseq=0` | Im Image bereits gesetzt; bei eigenem Image ergänzen |
| `cache_size=15460M` o. ä. | `--wiredTigerCacheSizeGB` setzen, sonst nimmt MongoDB ~50 % RAM |
| `Access control is not enabled` | Gewollt, solange Port 27017 nicht veröffentlicht ist |
| `transparent_hugepage`, `swappiness` | Kernel-Einstellungen des Hosts, für Homelab unkritisch |

## MongoDB-Build

### `cannot allocate memory` / `Killed signal terminated program cc1plus`

Speichermangel in der Docker-VM. Docker-Desktop-Speicher erhöhen und/oder `JOBS` verringern,
dann einfach neu starten – der Bazel-Cache im Volume `mongod-avx-bazel-cache` sorgt dafür,
dass es dort weitergeht. Läuft trotz `JOBS=2` mehr als zwei Compiler gleichzeitig, wurde
`JOBS` nicht übergeben (Variable in derselben Zeile wie der Aufruf setzen).

### `libatomic.so.1 => not found` beim Bau des Laufzeit-Images

Im aktuellen Dockerfile behoben (`libatomic1`). Ohne neu zu kompilieren:
`./build.sh --skip-compile --save`.

### `sed: 1: ...: invalid command code` auf macOS

Alte Version von `build.sh` mit `sed -i`; die aktuelle ist mit BSD-sed kompatibel.
