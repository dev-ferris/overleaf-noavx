#!/usr/bin/env bash
#
# Builds a MongoDB 8.0 image without the AVX requirement.
#
#   Step 1: build mongod from source (via Axcient/mongod-avx, Bazel, Ubuntu Noble)
#           OR take a prebuilt mongod from a release ZIP (--from-zip)
#   Step 2: AVX spot check on the binary (objdump)
#   Step 3: build a slim runtime image (Dockerfile in this directory)
#   Step 4: optionally export the image as .tar.gz for transfer to the target host (--save)
#
# Run on a machine with Docker, NOT on the NAS (the build needs a lot of CPU/RAM).
#
# Examples:
#   ./build.sh                                   # nehalem, build from source
#   CPU_ARCH=core2 ./build.sh                    # for CPUs without SSE4.2
#   JOBS=2 ./build.sh --save                     # limit parallelism (RAM!), then export
#                                                # after an abort simply run again: the Bazel cache
#                                                # lives in the volume mongod-avx-bazel-cache
#   docker volume rm mongod-avx-bazel-cache      # drop the cache (after a successful build)
#   ./build.sh --from-zip ~/Downloads/mongod.zip --save
#   ./build.sh --skip-compile --save             # reuse bin/mongod, only rebuild the image
#   MONGO_UID=999 MONGO_GID=999 ./build.sh       # match UID/GID of an existing volume

set -euo pipefail

# ---------------------------------------------------------------- Parameter
AXCIENT_REPO="https://github.com/Axcient/mongod-avx.git"
AXCIENT_TAG="${AXCIENT_TAG:-v8.0.17}"          # tag of the build repo (also pins the MongoDB version)
MONGO_VERSION="${MONGO_VERSION:-8.0.17}"
CPU_ARCH="${CPU_ARCH:-nehalem}"                 # nehalem (SSE4.2/POPCNT present) or core2
JOBS="${JOBS:-}"                               # empty = Bazel default (all cores)
BAZEL_JVM_MEM="${BAZEL_JVM_MEM:-2g}"           # heap limit of the Bazel server (Java)
CACHE_VOLUME="${CACHE_VOLUME:-mongod-avx-bazel-cache}"   # Docker volume for the Bazel cache
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
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-zip) FROM_ZIP="${2:?path to ZIP missing}"; shift 2 ;;
    --save)     SAVE=1; shift ;;
    --skip-compile) SKIP_COMPILE=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

case "${CPU_ARCH}" in
  nehalem|core2|westmere|silvermont|goldmont|goldmont-plus|tremont|x86-64-v2) ;;
  *) echo "Warning: CPU_ARCH=${CPU_ARCH} is unusual – it must not imply AVX!" >&2 ;;
esac

log() { printf '\n==> %s\n' "$*"; }

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
mkdir -p "${BIN}"

# ---------------------------------------------------------------- Step 1
if [[ "${SKIP_COMPILE}" -eq 1 ]]; then
  [[ -x "${BIN}/mongod" ]] || { echo "ERROR: ${BIN}/mongod missing – build without --skip-compile" >&2; exit 1; }
  log "Skipping compilation, using existing ${BIN}/mongod"
elif [[ -n "${FROM_ZIP}" ]]; then
  log "Taking mongod from ${FROM_ZIP}"
  command -v unzip >/dev/null || { echo "unzip missing" >&2; exit 1; }
  unzip -o -j "${FROM_ZIP}" '*mongod' -d "${BIN}"
else
  # Clone the repo only the first time: a fresh clone changes the build context
  # and would invalidate the Docker cache (including the multi-GB MongoDB clone).
  if [[ ! -d "${WORK}/.git" ]] || [[ "$(git -C "${WORK}" describe --tags 2>/dev/null)" != "${AXCIENT_TAG}" ]]; then
    log "Fetching build repo ${AXCIENT_REPO} @ ${AXCIENT_TAG}"
    rm -rf "${WORK}"
    git clone --branch "${AXCIENT_TAG}" --depth 1 "${AXCIENT_REPO}" "${WORK}"
  else
    log "Build repo present (${AXCIENT_TAG}) – using cache"
  fi

  # The Axcient Dockerfile compiles inside a RUN step. We split that off:
  #   Dockerfile.env  = environment (toolchain, sources, patches, Bazel)  -> docker build
  #   bazel-build.sh  = the actual bazel invocation                         -> docker run
  # Benefit: the Bazel cache lives in a volume. If the build aborts (e.g. OOM),
  # running again continues where it stopped instead of starting from scratch.
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
    || { echo "ERROR: bazel invocation not found in the Axcient Dockerfile (format changed?)" >&2; exit 1; }

  # Add memory-saving Bazel options (portable sed, no -i)
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
  log "Building build environment (slow the first time: clones MongoDB, installs Bazel)"
  docker build \
    --file "${ENV_DF}" \
    --build-arg CPU_ARCH="${CPU_ARCH}" \
    --tag "${ENV_TAG}" \
    "${WORK}"

  OUT="${WORK}/out"
  mkdir -p "${OUT}"
  log "Compiling mongod (${MONGO_VERSION}, -march=${CPU_ARCH}, jobs=${JOBS:-auto}) – this takes hours"
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

# ---------------------------------------------------------------- Step 2
log "AVX spot check (counts instructions using ymm/zmm registers)"
AVX_HITS="$(docker run --rm -v "${BIN}:/b:ro" ubuntu:noble bash -c \
  'apt-get -qq update >/dev/null && apt-get -qq install -y binutils >/dev/null \
   && objdump -d --no-show-raw-insn /b/mongod > /tmp/dis \
   && grep -cE "%[yz]mm" /tmp/dis || true')"
echo "Hits: ${AVX_HITS}"
if [[ "${AVX_HITS}" != "0" ]]; then
  echo "Affected functions:"
  docker run --rm -v "${BIN}:/b:ro" ubuntu:noble bash -c \
    'apt-get -qq update >/dev/null && apt-get -qq install -y binutils >/dev/null \
     && objdump -d --no-show-raw-insn -C /b/mongod \
      | awk "/^[0-9a-f]+ </{fn=\$0} /%[yz]mm/{print fn}" | sort | uniq -c | head -20'
  echo "Note: ${AVX_HITS} AVX instructions found. They may be guarded by a runtime CPUID check;"
  echo "      the decisive test is running on the target host (SIGILL = 'Illegal instruction')."
fi

# ---------------------------------------------------------------- Step 3
log "Building runtime image ${IMAGE}"
docker build \
  --build-arg MONGO_VERSION="${MONGO_VERSION}" \
  --build-arg CPU_ARCH="${CPU_ARCH}" \
  --build-arg MONGO_UID="${MONGO_UID}" \
  --build-arg MONGO_GID="${MONGO_GID}" \
  --tag "${IMAGE}" \
  "${HERE}"

docker run --rm "${IMAGE}" --version

# ---------------------------------------------------------------- Step 4
if [[ "${SAVE}" -eq 1 ]]; then
  TARBALL="${HERE}/$(echo "${IMAGE}" | tr ':/' '__').tar.gz"
  log "Exporting to ${TARBALL}"
  docker save "${IMAGE}" | gzip > "${TARBALL}"
  ls -lh "${TARBALL}"
  echo
  echo "Load on the target host with:  gunzip -c $(basename "${TARBALL}") | docker load"
fi

log "Done: ${IMAGE}"
