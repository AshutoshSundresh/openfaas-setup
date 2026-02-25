#!/usr/bin/env bash
set -euo pipefail

REDIS_HOST="${REDIS_HOST:-redis.openfaas.svc.cluster.local}"
REDIS_PORT="${REDIS_PORT:-6379}"
FN_NAME="${FN_NAME:-profile-fn}"
FN_VERSION="${FN_VERSION:-v1}"
POD_UID="${POD_UID:-unknown}"

PROFILE_DIR="/profiles"
IN_PROFILE="${PROFILE_DIR}/in.profile"
OUT_PROFILE="${PROFILE_DIR}/out.profile"
ARTIFACT_KEY="artifact:${FN_NAME}:${FN_VERSION}"
TERMINATED_KEY="terminated:${POD_UID}"
JAVA_DRAIN_S=10   # bounded wait for JVM shutdown before forced SIGKILL

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)] $*"; }
rcmd() { redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" "$@"; }

# ── SIGTERM HANDLER (installed FIRST, before any blocking work) ───────────────
JAVA_PID=""
ARTIFACT=""

_term() {
  log "TERM_HANDLER_START pod=${POD_UID} t=$(date -u +%s%3N)"

  # Phase 1: signal JVM, give it bounded time to flush to disk
  if [ -n "${JAVA_PID}" ]; then
    kill -TERM "${JAVA_PID}" 2>/dev/null || true
    for _ in $(seq 1 "${JAVA_DRAIN_S}"); do
      kill -0 "${JAVA_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "${JAVA_PID}" 2>/dev/null || true   # force if still alive
    wait "${JAVA_PID}"       2>/dev/null || true
  fi

  # Phase 2: push artifact (JVM has exited, files are stable)
  NOW_MS=$(date -u +%s%3N)
  if [ -f "${OUT_PROFILE}" ]; then
    PUSH_PAYLOAD=$(cat "${OUT_PROFILE}")
  else
    COUNTER=$(printf '%s' "${ARTIFACT}" | jq -r '.counter // 0' 2>/dev/null || echo "0")
    COUNTER=$((COUNTER + 1))
    PUSH_PAYLOAD=$(jq -n \
      --arg  pod "${POD_UID}" \
      --argjson ms  "${NOW_MS}" \
      --argjson cnt "${COUNTER}" \
      '{"version":"v1","last_writer_pod":$pod,"write_time_ms":$ms,"counter":$cnt,"notes":"pushed_by_wrapper"}')
  fi

  rcmd SET "${ARTIFACT_KEY}"   "${PUSH_PAYLOAD}"
  rcmd SET "${TERMINATED_KEY}" \
    "$(jq -n --arg pod "${POD_UID}" --argjson ms "${NOW_MS}" \
        '{"pod":$pod,"terminated_ms":$ms}')"

  log "POST_PUSH_DONE pod=${POD_UID} t=$(date -u +%s%3N)"
}

trap '_term' SIGTERM SIGINT

# ── PRE-PULL ──────────────────────────────────────────────────────────────────
mkdir -p "${PROFILE_DIR}"
log "PRE_PULL_START pod=${POD_UID}"

ARTIFACT=$(rcmd GET "${ARTIFACT_KEY}" 2>/dev/null || true)
if [ -z "${ARTIFACT}" ]; then
  log "ARTIFACT_MISSING pod=${POD_UID} key=${ARTIFACT_KEY}"
  ARTIFACT='{"version":"v1","last_writer_pod":"none","write_time_ms":0,"counter":0,"notes":"initial"}'
fi

printf '%s' "${ARTIFACT}" > "${IN_PROFILE}"
log "PRE_PULL_DONE pod=${POD_UID} t=$(date -u +%s%3N)"

# ── START JVM ────────────────────────────────────────────────────────────────
log "JAVA_STARTING pod=${POD_UID} t=$(date -u +%s%3N)"
java -jar /app/function.jar &
JAVA_PID=$!
log "JAVA_STARTED pod=${POD_UID} pid=${JAVA_PID} t=$(date -u +%s%3N)"

wait "${JAVA_PID}"
