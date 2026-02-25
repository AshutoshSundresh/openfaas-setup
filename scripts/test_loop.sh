#!/usr/bin/env bash
# test_loop.sh — runs N cold-start cycles and verifies ordering invariants.
#
# For each trial:
#   1. Invoke the function (cold start if needed)
#   2. Verify Redis has a `started:<podUID>` key
#   3. Delete the pod (triggers SIGTERM → wrapper push)
#   4. Wait for pod to fully terminate
#   5. Verify Redis has `terminated:<podUID>` and an updated artifact
#
# Usage:
#   TRIALS=20 GATEWAY=http://127.0.0.1:8080 ./scripts/test_loop.sh

set -euo pipefail

# Pre-flight: verify required tools are on PATH
MISSING=()
for tool in kubectl curl jq redis-cli; do
  command -v "${tool}" &>/dev/null || MISSING+=("${tool}")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: missing required tools: ${MISSING[*]}"
  echo "Install them and ensure they are on PATH before running this script."
  echo "See README.md for installation instructions."
  exit 1
fi

GATEWAY="${GATEWAY:-http://127.0.0.1:8080}"
FN_NAME="${FN_NAME:-profile-fn}"
FN_NAMESPACE="${FN_NAMESPACE:-openfaas-fn}"
TRIALS="${TRIALS:-10}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"   # assumes: kubectl port-forward svc/redis 6379:6379 -n openfaas
REDIS_PORT="${REDIS_PORT:-6379}"
FN_VERSION="${FN_VERSION:-v1}"
GRACE_EXTRA_S=5   # extra seconds to wait after pod gone before checking Redis

PASS=0
FAIL=0
declare -a RESULTS=()

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)] $*"; }

die() { log "FATAL: $*"; exit 1; }

rget() {
  redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" GET "$1" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
log "Starting ${TRIALS} trials  gateway=${GATEWAY}  fn=${FN_NAME}  namespace=${FN_NAMESPACE}"
echo ""

# ── Pre-loop: force a fresh pod so trial 1 reads the current artifact ─────────
# Any already-running pod may have started before the last push and hold a stale
# artifact in memory. Cycling it here ensures the baseline counter we read below
# matches what the trial 1 pod will actually see at startup.
log "PRE-LOOP: cycling pod to ensure trial 1 starts fresh..."
kubectl delete pod -n "${FN_NAMESPACE}" -l "faas_function=${FN_NAME}" \
  --grace-period=20 2>/dev/null || true
kubectl wait --for=delete pod \
  -n "${FN_NAMESPACE}" -l "faas_function=${FN_NAME}" \
  --timeout=40s 2>/dev/null || true
log "PRE-LOOP: waiting for replacement pod..."
sleep 8

# Read baseline AFTER the pre-loop push has landed in Redis.
EXISTING=$(rget "artifact:${FN_NAME}:${FN_VERSION}")
if [ -z "${EXISTING}" ]; then
  log "No existing artifact — trial 1 will seed Redis from default (counter=0 → 1)"
  PREV_COUNTER=0
else
  PREV_COUNTER=$(echo "${EXISTING}" | jq -r '.counter // 0' 2>/dev/null || echo "0")
  log "Baseline counter=${PREV_COUNTER} (read after pre-loop)"
fi
echo ""

for i in $(seq 1 "${TRIALS}"); do
  log "══ Trial ${i}/${TRIALS} ══════════════════════════════════════════"
  TRIAL_PASS=true

  # ── 1. Invoke ──────────────────────────────────────────────────────────────
  log "Invoking ${FN_NAME}..."
  RESPONSE=$(curl -sf --max-time 30 "${GATEWAY}/function/${FN_NAME}" 2>/dev/null || echo "__FAIL__")
  if [ "${RESPONSE}" = "__FAIL__" ]; then
    log "FAIL: invocation error"
    FAIL=$((FAIL+1))
    RESULTS+=("trial=${i} FAIL reason=invocation_error")
    continue
  fi
  log "Response: ${RESPONSE}"

  POD_UID=$(echo "${RESPONSE}"      | jq -r '.pod'           2>/dev/null || echo "unknown")
  ARTIFACT_HASH=$(echo "${RESPONSE}" | jq -r '.artifact_hash' 2>/dev/null || echo "unknown")
  RUNSEQ=$(echo "${RESPONSE}"       | jq -r '.runseq'        2>/dev/null || echo "?")
  log "pod_uid=${POD_UID}  artifact_hash=${ARTIFACT_HASH}  runseq=${RUNSEQ}"

  # ── 2. Verify started key ──────────────────────────────────────────────────
  STARTED=$(rget "started:${POD_UID}")
  if [ -z "${STARTED}" ]; then
    log "FAIL: no started key for pod ${POD_UID}"
    FAIL=$((FAIL+1))
    RESULTS+=("trial=${i} FAIL reason=no_started_key pod=${POD_UID}")
    continue
  fi
  log "started key present: ${STARTED}"

  # ── 3. Find and delete the pod ────────────────────────────────────────────
  POD=$(kubectl get pod -n "${FN_NAMESPACE}" \
        -l "faas_function=${FN_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [ -z "${POD}" ]; then
    log "FAIL: could not locate pod for ${FN_NAME}"
    FAIL=$((FAIL+1))
    RESULTS+=("trial=${i} FAIL reason=pod_not_found")
    continue
  fi
  log "Deleting pod ${POD} (grace=20s)..."
  kubectl delete pod -n "${FN_NAMESPACE}" "${POD}" --grace-period=20 2>/dev/null || true

  # ── 4. Wait for pod gone ──────────────────────────────────────────────────
  log "Waiting for pod termination..."
  kubectl wait --for=delete "pod/${POD}" -n "${FN_NAMESPACE}" --timeout=40s 2>/dev/null || true
  sleep "${GRACE_EXTRA_S}"   # let wrapper finish Redis write before we check

  # ── 5. Verify terminated key and artifact update ──────────────────────────
  TERMINATED=$(rget "terminated:${POD_UID}")
  if [ -z "${TERMINATED}" ]; then
    log "FAIL: no terminated key for pod ${POD_UID}"
    TRIAL_PASS=false
  else
    log "terminated key present: ${TERMINATED}"
  fi

  ARTIFACT=$(rget "artifact:${FN_NAME}:${FN_VERSION}")
  if [ -z "${ARTIFACT}" ]; then
    log "FAIL: artifact key missing after termination"
    TRIAL_PASS=false
  else
    NEW_COUNTER=$(echo "${ARTIFACT}" | jq -r '.counter // 0' 2>/dev/null || echo "0")
    LAST_WRITER=$(echo "${ARTIFACT}" | jq -r '.last_writer_pod // "?"' 2>/dev/null || echo "?")
    EXPECTED_COUNTER=$((PREV_COUNTER + 1))
    if [ "${NEW_COUNTER}" -ne "${EXPECTED_COUNTER}" ]; then
      log "FAIL: counter not incremented  expected=${EXPECTED_COUNTER}  got=${NEW_COUNTER}"
      TRIAL_PASS=false
    else
      log "artifact counter=${NEW_COUNTER} (expected ${EXPECTED_COUNTER})  last_writer=${LAST_WRITER}"
      PREV_COUNTER="${NEW_COUNTER}"
    fi
  fi

  if ${TRIAL_PASS}; then
    log "Trial ${i}: PASS"
    PASS=$((PASS+1))
    RESULTS+=("trial=${i} PASS pod=${POD_UID} runseq=${RUNSEQ} hash=${ARTIFACT_HASH}")
  else
    FAIL=$((FAIL+1))
    RESULTS+=("trial=${i} FAIL pod=${POD_UID}")
  fi

  echo ""
  # Give OpenFaaS a moment to notice the pod is gone before next invoke
  log "Waiting for function to scale back up..."
  sleep 5
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo " Results: ${PASS} passed / ${FAIL} failed / ${TRIALS} total"
echo "════════════════════════════════════════════════════"
for r in "${RESULTS[@]}"; do echo "  ${r}"; done
echo ""

[ "${FAIL}" -eq 0 ] && exit 0 || exit 1
