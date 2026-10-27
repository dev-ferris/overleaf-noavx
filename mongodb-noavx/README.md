# MongoDB 8.0 ohne AVX

Overleaf 6.x setzt MongoDB 8.0 voraus. Die offiziellen MongoDB-Binaries ab 5.0 brauchen eine CPU
mit AVX – viele NAS- und Mini-PC-CPUs (Celeron J4105/J4125, Pentium Silver, Atom) haben das nicht
und brechen beim Start mit `Illegal instruction` ab.

Dieses Verzeichnis baut MongoDB 8.0.17 ohne AVX-Anforderung als Docker-Image. Die eigentliche
Arbeit (Patches gegen AVX in mozjs und Bazel, `-march=nehalem`/`core2`) stammt aus
[Axcient/mongod-avx](https://github.com/Axcient/mongod-avx); `build.sh` macht daraus einen
fortsetzbaren Build und ein schlankes Laufzeit-Image.

| Datei | Zweck |
|---|---|
| `build.sh` | Kompiliert `mongod` (oder übernimmt ein vorhandenes) und baut das Laufzeit-Image |
| `Dockerfile` | Laufzeit-Image: Ubuntu Noble, Entrypoint `mongod`, User `mongodb`, `/data/db` |

Das Image verhält sich wie [`ghcr.io/fenio/mongodb-no-avx`](https://github.com/fenio/mongodb-no-avx)
(MongoDB 7.0 ohne AVX), ist also ein Drop-in-Ersatz: `command: "--replSet rs0 ..."` bleibt gleich.

---

## 1. Ziel-CPU bestimmen (auf dem Zielsystem)

```bash
grep -o -w -E 'avx|sse4_2|popcnt' /proc/cpuinfo | sort -u
```

| Ausgabe | Bedeutung |
|---|---|
| enthält `avx` | Kein Eigenbau nötig – offizielles `mongo:8.0` verwenden |
| `sse4_2` + `popcnt`, kein `avx` | `CPU_ARCH=nehalem` (Standard) |
| kein `sse4_2` | `CPU_ARCH=core2` |

Wer ein bestehendes MongoDB-Volume weiterverwenden will, prüft außerdem die UID im alten Image:

```bash
docker run --rm --entrypoint id ghcr.io/fenio/mongodb-no-avx:7.0.28
```

und übergibt sie als `MONGO_UID`/`MONGO_GID` (Standard: 999).

## 2. Bauen (auf einem leistungsfähigen x86_64-Rechner, nicht auf dem NAS)

Voraussetzungen: Docker, x86_64 (Linux oder Intel-Mac mit Docker Desktop), bash, git.

```bash
cd mongodb-noavx
CPU_ARCH=nehalem JOBS=2 ./build.sh --save
```

Ergebnis: Image `mongodb-no-avx:8.0.17-nehalem` und die Datei `mongodb-no-avx_8.0.17-nehalem.tar.gz`.

### Ressourcen und Dauer

Der Build ist speicherhungrig: Einzelne Übersetzungseinheiten brauchen 1,5–2 GB RAM, der
Bazel-Server weitere 2 GB. **Ausschlaggebend ist der RAM der Docker-VM**, nicht der des Hosts –
bei Docker Desktop unter *Settings → Resources* einstellen.

| Speicher der Docker-VM | `JOBS` |
|---|---|
| 8 GB | `1` (knapp, besser erhöhen) |
| 12 GB | `2` |
| 24 GB | `4`–`6` |

Plattenplatz: mindestens 80 GB (Docker-Disk-Limit entsprechend anheben).

Erfahrungswert: Intel-Mac, 12 GB Docker-VM, `JOBS=2` → rund 12 Stunden reine Bauzeit.
`caffeinate -i` vor den Aufruf setzen, damit der Mac nicht schläft.

### Abbruch und Fortsetzen

Bricht der Build ab (typisch: `Killed signal terminated program cc1plus` = Speichermangel),
einfach mit kleinerem `JOBS` erneut starten. Der Bazel-Cache liegt im Docker-Volume
`mongod-avx-bazel-cache`; bereits kompilierte Teile werden nicht wiederholt.

Nach erfolgreichem Build kann der Cache weg:

```bash
docker volume rm mongod-avx-bazel-cache
```

### Optionen

| Variable / Option | Standard | Bedeutung |
|---|---|---|
| `CPU_ARCH` | `nehalem` | GCC-`-march`-Ziel, darf kein AVX enthalten |
| `JOBS` | alle Kerne | Parallele Compiler-Prozesse |
| `BAZEL_JVM_MEM` | `2g` | Heap-Limit des Bazel-Servers |
| `MONGO_UID` / `MONGO_GID` | `999` | UID/GID des `mongodb`-Users im Image |
| `AXCIENT_TAG` / `MONGO_VERSION` | `v8.0.17` / `8.0.17` | Version |
| `IMAGE` | `mongodb-no-avx:<version>-<arch>` | Name des erzeugten Images |
| `--save` | – | Image zusätzlich als `.tar.gz` exportieren |
| `--skip-compile` | – | Vorhandenes `bin/mongod` verwenden, nur Image neu bauen |
| `--from-zip <datei>` | – | `mongod` aus einem ZIP (z. B. Axcient-Release) übernehmen |

### AVX-Stichprobe

`build.sh` zählt im fertigen Binary Befehle mit `ymm`/`zmm`-Registern und listet die
betroffenen Funktionen. Einige wenige Treffer (beim Referenz-Build: 11) sind normal – das sind
Codepfade, die zur Laufzeit per CPUID abgesichert sind. Der entscheidende Test ist der Start auf
dem Zielsystem.

## 3. Aufs NAS bringen und testen

Per Datei:

```bash
scp mongodb-no-avx_8.0.17-nehalem.tar.gz user@zielhost:/tmp/
ssh user@zielhost 'gunzip -c /tmp/mongodb-no-avx_8.0.17-nehalem.tar.gz | docker load'
```

Oder über eine Registry (Docker Hub oder ghcr.io):

```bash
docker tag mongodb-no-avx:8.0.17-nehalem ghcr.io/<user>/mongodb-no-avx:8.0.17-nehalem
docker push ghcr.io/<user>/mongodb-no-avx:8.0.17-nehalem
```

Pakete auf ghcr.io sind zunächst privat; das NAS braucht dann ein `docker login ghcr.io`
mit einem Token mit `read:packages`.

**Smoke-Test auf dem NAS:**

```bash
docker run --rm mongodb-no-avx:8.0.17-nehalem --version
```

`Illegal instruction` bzw. Exit-Code 132 → Binary für diese CPU zu „modern“, mit `CPU_ARCH=core2`
neu bauen (ändert die Compiler-Flags, der Bazel-Cache greift dann nicht).

## 4. Update auf neuere 8.0.x

Sobald Axcient einen neuen Tag veröffentlicht:

```bash
AXCIENT_TAG=v8.0.xx MONGO_VERSION=8.0.xx CPU_ARCH=nehalem JOBS=2 ./build.sh --save
```

Patch-Updates innerhalb 8.0 brauchen keine Änderung der Feature Compatibility Version.

## Hinweise

- Inoffizieller Build, von MongoDB weder getestet noch unterstützt. Für Homelab-Daten mit
  regelmäßigem Backup vertretbar, für produktive Systeme nicht.
- MongoDB steht unter der [SSPL](https://www.mongodb.com/legal/licensing/server-side-public-license).
  Ein selbst gebautes Image privat zu nutzen ist unproblematisch; wer es öffentlich verteilt,
  sollte die Lizenzbedingungen kennen.
- Sicherheitsupdates kommen nur, wenn du neu baust.
