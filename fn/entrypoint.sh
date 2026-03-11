#!/usr/bin/env bash
set -euo pipefail

REDIS_HOST="${REDIS_HOST:-redis.openfaas.svc.cluster.local}"
REDIS_PORT="${REDIS_PORT:-6379}"
FN_NAME="${FN_NAME:-profile-fn}"
FN_VERSION="${FN_VERSION:-v1}"
POD_UID="${POD_UID:-unknown}"

PROFILE_DIR="/profiles"
MDOX_FILE="${PROFILE_DIR}/profile.mdox"
ARTIFACT_KEY="artifact:${FN_NAME}:${FN_VERSION}"
TERMINATED_KEY="terminated:${POD_UID}"
JAVA_DRAIN_S=10   # bounded wait for JVM shutdown before forced SIGKILL

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)] $*"; }
rcmd() { redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" "$@"; }

# ── SIGTERM HANDLER (installed FIRST, before any blocking work) ───────────────
JAVA_PID=""

_term() {
  log "TERM_HANDLER_START pod=${POD_UID} t=$(date -u +%s%3N)"

  # Phase 1: signal JVM, give it bounded time to flush
  # DumpMDOAtExit causes the JVM to write profile.mdox on clean shutdown
  if [ -n "${JAVA_PID}" ]; then
    kill -TERM "${JAVA_PID}" 2>/dev/null || true
    for _ in $(seq 1 "${JAVA_DRAIN_S}"); do
      kill -0 "${JAVA_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "${JAVA_PID}" 2>/dev/null || true   # force if still alive
    wait "${JAVA_PID}"       2>/dev/null || true
  fi

  # Phase 2: push binary MDOX profile back to Redis (base64-encoded)
  NOW_MS=$(date -u +%s%3N)
  if [ -f "${MDOX_FILE}" ] && [ -s "${MDOX_FILE}" ]; then
    MDOX_SIZE=$(stat -c%s "${MDOX_FILE}" 2>/dev/null || stat -f%z "${MDOX_FILE}" 2>/dev/null || echo 0)
    log "POST_PUSH pushing MDOX profile size=${MDOX_SIZE} bytes"
    # Pipe base64 via stdin (-x) to avoid shell argument length limit
    base64 -w0 < "${MDOX_FILE}" | redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -x SET "${ARTIFACT_KEY}"
  else
    MDOX_SIZE=0
    log "POST_PUSH no MDOX file found at ${MDOX_FILE}, pushing empty marker"
    rcmd SET "${ARTIFACT_KEY}" "__EMPTY__"
  fi

  # Write metadata about this push
  rcmd SET "meta:${ARTIFACT_KEY}" \
    "$(jq -n \
        --arg  pod "${POD_UID}" \
        --argjson ms  "${NOW_MS}" \
        --argjson sz  "${MDOX_SIZE}" \
        '{"last_writer_pod":$pod,"write_time_ms":$ms,"mdox_size":$sz}')"

  rcmd SET "${TERMINATED_KEY}" \
    "$(jq -n --arg pod "${POD_UID}" --argjson ms "${NOW_MS}" \
        '{"pod":$pod,"terminated_ms":$ms}')"

  log "POST_PUSH_DONE pod=${POD_UID} t=$(date -u +%s%3N)"
}

trap '_term' SIGTERM SIGINT

# ── PRE-PULL ──────────────────────────────────────────────────────────────────
mkdir -p "${PROFILE_DIR}"
log "PRE_PULL_START pod=${POD_UID}"

# Pull base64-encoded MDOX profile from Redis
B64_DATA=$(rcmd --raw GET "${ARTIFACT_KEY}" 2>/dev/null || true)

if [ -z "${B64_DATA}" ] || [ "${B64_DATA}" = "__EMPTY__" ]; then
  log "ARTIFACT_MISSING pod=${POD_UID} key=${ARTIFACT_KEY} (first run, no profile to restore)"
  HAVE_PROFILE=false
else
  # Decode base64 back to binary MDOX file
  echo -n "${B64_DATA}" | base64 -d > "${MDOX_FILE}" 2>/dev/null || true

  # Validate: MDOX files start with magic bytes 'M','D','O','X'
  if [ -f "${MDOX_FILE}" ] && [ -s "${MDOX_FILE}" ]; then
    MAGIC=$(head -c 4 "${MDOX_FILE}" 2>/dev/null || true)
    if [ "${MAGIC}" = "MDOX" ]; then
      MDOX_SIZE=$(stat -c%s "${MDOX_FILE}" 2>/dev/null || stat -f%z "${MDOX_FILE}" 2>/dev/null || echo 0)
      log "PRE_PULL restored MDOX profile size=${MDOX_SIZE} bytes"
      HAVE_PROFILE=true
    else
      log "PRE_PULL invalid profile data, ignoring"
      rm -f "${MDOX_FILE}"
      HAVE_PROFILE=false
    fi
  else
    log "PRE_PULL empty profile data, ignoring"
    rm -f "${MDOX_FILE}"
    HAVE_PROFILE=false
  fi
fi

log "PRE_PULL_DONE pod=${POD_UID} have_profile=${HAVE_PROFILE} t=$(date -u +%s%3N)"

# ── BUILD JVM FLAGS ──────────────────────────────────────────────────────────
# Always dump profile on exit so the next pod can use it
JVM_PROFILE_FLAGS=(
  "-XX:+UnlockDiagnosticVMOptions"
  "-XX:+DumpMDOAtExit"
  "-XX:MDOReplayDumpFile=${MDOX_FILE}"
)

# If we have an existing profile, load it at startup for warm JIT
if [ "${HAVE_PROFILE}" = "true" ]; then
  JVM_PROFILE_FLAGS+=(
    "-XX:+LoadMDOAtStartup"
    "-XX:MDOReplayLoadFile=${MDOX_FILE}"
    "-XX:+EagerCompileAfterLoad"
  )
fi

# ── START JVM ────────────────────────────────────────────────────────────────
log "JAVA_STARTING pod=${POD_UID} have_profile=${HAVE_PROFILE} t=$(date -u +%s%3N)"
java "${JVM_PROFILE_FLAGS[@]}" \
     --add-exports java.base/jdk.internal.profilecheckpoint=ALL-UNNAMED \
     -jar /app/function.jar &
JAVA_PID=$!
log "JAVA_STARTED pod=${POD_UID} pid=${JAVA_PID} t=$(date -u +%s%3N)"

wait "${JAVA_PID}"
