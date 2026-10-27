#!/usr/bin/env bash
#
# Baut ein MongoDB-8.0-Image ohne AVX-Anforderung.
#
#   Schritt 1: mongod aus den Quellen bauen (über Axcient/mongod-avx, Bazel, Ubuntu Noble)
#              ODER ein fertiges mongod aus einem Release-ZIP übernehmen (--from-zip)
#   Schritt 2: AVX-Stichprobe im Binary (objdump)
#   Schritt 3: schlankes Laufzeit-Image bauen (Dockerfile in diesem Ordner)
#   Schritt 4: optional Image als .tar.gz für den Transfer aufs NAS exportieren (--save)
#
# Auf einer Maschine mit Docker ausführen, NICHT auf dem NAS (Build braucht viel CPU/RAM).
#
# Beispiele:
#   ./build.sh                                   # nehalem, Quell-Build
#   CPU_ARCH=core2 ./build.sh                    # für CPUs ohne SSE4.2
#   JOBS=2 ./build.sh --save                     # Parallelität begrenzen (RAM!), danach exportieren
#                                                # nach Abbruch einfach erneut starten: Bazel-Cache
#                                                # liegt im Volume mongod-avx-bazel-cache
#   docker volume rm mongod-avx-bazel-cache      # Cache verwerfen (nach erfolgreichem Build)
#   ./build.sh --from-zip ~/Downloads/mongod.zip --save
#   MONGO_UID=999 MONGO_GID=999 ./build.sh       # UID/GID an bestehendes Volume anpassen

set -euo pipefail

# ---------------------------------------------------------------- Parameter
AXCIENT_REPO="https://github.com/Axcient/mongod-avx.git"
AXCIENT_TAG="${AXCIENT_TAG:-v8.0.17}"          # Tag des Build-Repos (pinnt auch die MongoDB-Version)
MONGO_VERSION="${MONGO_VERSION:-8.0.17}"
CPU_ARCH="${CPU_ARCH:-nehalem}"                 # nehalem (SSE4.2/POPCNT vorhanden) oder core2
JOBS="${JOBS:-}"                               # leer = Bazel-Default (alle Kerne)
BAZEL_JVM_MEM="${BAZEL_JVM_MEM:-2g}"           # Heap-Limit des Bazel-Servers (Java)
CACHE_VOLUME="${CACHE_VOLUME:-mongod-avx-bazel-cache}"   # Docker-Volume für den Bazel-Cache
MONGO_UID="${MONGO_UID:-999}"
MONGO_GID="${MONGO_GID:-999}"
IMAGE="${IMAGE:-mongodb-no-avx:${MONGO_VERSION}-${CPU_ARCH}}"

FROM_ZIP=""
SAVE=0
SKIP_COMPILE=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${HERE}/work"
BIN="${HERE}/bin"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-zip) FROM_ZIP="${2:?Pfad zum ZIP fehlt}"; shift 2 ;;
    --save)     SAVE=1; shift ;;
    --skip-compile) SKIP_COMPILE=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          echo "Unbekannte Option: $1" >&2; usage 1 ;;
  esac
done

case "${CPU_ARCH}" in
  nehalem|core2|westmere|silvermont|goldmont|goldmont-plus|tremont|x86-64-v2) ;;
  *) echo "Warnung: CPU_ARCH=${CPU_ARCH} ist ungewöhnlich – darf kein AVX implizieren!" >&2 ;;
esac

log() { printf '\n==> %s\n' "$*"; }

command -v docker >/dev/null || { echo "docker nicht gefunden" >&2; exit 1; }
mkdir -p "${BIN}"

# ---------------------------------------------------------------- Schritt 1
if [[ "${SKIP_COMPILE}" -eq 1 ]]; then
  [[ -x "${BIN}/mongod" ]] || { echo "FEHLER: ${BIN}/mongod fehlt – ohne --skip-compile bauen" >&2; exit 1; }
  log "Überspringe Kompilierung, verwende vorhandenes ${BIN}/mongod"
elif [[ -n "${FROM_ZIP}" ]]; then
  log "Übernehme mongod aus ${FROM_ZIP}"
  command -v unzip >/dev/null || { echo "unzip fehlt" >&2; exit 1; }
  unzip -o -j "${FROM_ZIP}" '*mongod' -d "${BIN}"
else
  # Repo nur beim ersten Mal klonen: ein frischer Klon ändert den Build-Kontext
  # und würde den Docker-Cache (inkl. des mehrere GB großen MongoDB-Klons) verwerfen.
  if [[ ! -d "${WORK}/.git" ]] || [[ "$(git -C "${WORK}" describe --tags 2>/dev/null)" != "${AXCIENT_TAG}" ]]; then
    log "Hole Build-Repo ${AXCIENT_REPO} @ ${AXCIENT_TAG}"
    rm -rf "${WORK}"
    git clone --branch "${AXCIENT_TAG}" --depth 1 "${AXCIENT_REPO}" "${WORK}"
  else
    log "Build-Repo vorhanden (${AXCIENT_TAG}) – verwende Cache"
  fi

  # Das Axcient-Dockerfile kompiliert in einem RUN-Schritt. Den trennen wir ab:
  #   Dockerfile.env  = Umgebung (Toolchain, Quellen, Patches, Bazel)  -> docker build
  #   bazel-build.sh  = der eigentliche bazel-Aufruf                    -> docker run
  # Vorteil: Der Bazel-Cache liegt in einem Volume. Bricht der Build ab (z. B. OOM),
  # macht ein erneuter Aufruf dort weiter, statt bei null anzufangen.
  SRC_DF="${WORK}/Dockerfile-noble"
  ENV_DF="${WORK}/Dockerfile.env"
  BAZEL_SH="${WORK}/bazel-build.sh"

  awk -v cmd="${BAZEL_SH}" '
    /^RUN USE_NATIVE_TOOLCHAIN=1 bazel build/ { inblk=1 }
    inblk { sub(/^RUN /, ""); print > cmd; if ($0 !~ /\\[[:space:]]*$/) inblk=0; next }
    /^ENTRYPOINT/ { next }
    { print }
  ' "${SRC_DF}" > "${ENV_DF}"

  grep -q "bazel build" "${BAZEL_SH}" 2>/dev/null \
    || { echo "FEHLER: bazel-Aufruf im Axcient-Dockerfile nicht gefunden (Format geändert?)" >&2; exit 1; }

  # Speicherschonende Bazel-Optionen ergänzen (portables sed, kein -i)
  JOBS_OPT=""; [[ -n "${JOBS}" ]] && JOBS_OPT="--jobs=${JOBS} "
  sed "s|bazel build |bazel --host_jvm_args=-Xmx${BAZEL_JVM_MEM} build ${JOBS_OPT}--discard_analysis_cache --nokeep_state_after_build |" \
    "${BAZEL_SH}" > "${BAZEL_SH}.tmp"
  { echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'; echo 'cd /src/mongo'
    cat "${BAZEL_SH}.tmp"; echo
    echo 'mkdir -p /tmp/output && cp -L bazel-bin/src/mongo/db/mongod /tmp/output/mongod'
  } > "${BAZEL_SH}"
  rm -f "${BAZEL_SH}.tmp"
  chmod +x "${BAZEL_SH}"

  ENV_TAG="mongod-avx-env:${MONGO_VERSION}-${CPU_ARCH}"
  log "Baue Build-Umgebung (beim ersten Mal lang: klont MongoDB, installiert Bazel)"
  docker build \
    --file "${ENV_DF}" \
    --build-arg CPU_ARCH="${CPU_ARCH}" \
    --tag "${ENV_TAG}" \
    "${WORK}"

  OUT="${WORK}/out"
  mkdir -p "${OUT}"
  log "Kompiliere mongod (${MONGO_VERSION}, -march=${CPU_ARCH}, jobs=${JOBS:-auto}) – das dauert Stunden"
  docker run --rm \
    -e CPU_ARCH="${CPU_ARCH}" \
    -v "${CACHE_VOLUME}:/root/.cache/bazel" \
    -v "${BAZEL_SH}:/bazel-build.sh:ro" \
    -v "${OUT}:/tmp/output" \
    --entrypoint bash \
    "${ENV_TAG}" /bazel-build.sh

  cp -f "${OUT}/mongod" "${BIN}/mongod"
fi

chmod 0755 "${BIN}/mongod"
ls -lh "${BIN}/mongod"

# ---------------------------------------------------------------- Schritt 2
log "AVX-Stichprobe (zählt Befehle mit ymm/zmm-Registern)"
AVX_HITS="$(docker run --rm -v "${BIN}:/b:ro" ubuntu:noble bash -c \
  'apt-get -qq update >/dev/null && apt-get -qq install -y binutils >/dev/null \
   && objdump -d --no-show-raw-insn /b/mongod > /tmp/dis \
   && grep -cE "%[yz]mm" /tmp/dis || true')"
echo "Treffer: ${AVX_HITS}"
if [[ "${AVX_HITS}" != "0" ]]; then
  echo "Betroffene Funktionen:"
  docker run --rm -v "${BIN}:/b:ro" ubuntu:noble bash -c \
    'apt-get -qq update >/dev/null && apt-get -qq install -y binutils >/dev/null \
     && objdump -d --no-show-raw-insn -C /b/mongod \
      | awk "/^[0-9a-f]+ </{fn=\$0} /%[yz]mm/{print fn}" | sort | uniq -c | head -20'
  echo "Hinweis: ${AVX_HITS} AVX-Befehle gefunden. Das kann zur Laufzeit per CPUID abgesichert sein,"
  echo "         der entscheidende Test ist der Start auf dem NAS (SIGILL = 'Illegal instruction')."
fi

# ---------------------------------------------------------------- Schritt 3
log "Baue Laufzeit-Image ${IMAGE}"
docker build \
  --build-arg MONGO_VERSION="${MONGO_VERSION}" \
  --build-arg CPU_ARCH="${CPU_ARCH}" \
  --build-arg MONGO_UID="${MONGO_UID}" \
  --build-arg MONGO_GID="${MONGO_GID}" \
  --tag "${IMAGE}" \
  "${HERE}"

docker run --rm "${IMAGE}" --version

# ---------------------------------------------------------------- Schritt 4
if [[ "${SAVE}" -eq 1 ]]; then
  TARBALL="${HERE}/$(echo "${IMAGE}" | tr ':/' '__').tar.gz"
  log "Exportiere nach ${TARBALL}"
  docker save "${IMAGE}" | gzip > "${TARBALL}"
  ls -lh "${TARBALL}"
  echo
  echo "Auf dem NAS laden mit:  gunzip -c $(basename "${TARBALL}") | docker load"
fi

log "Fertig: ${IMAGE}"
