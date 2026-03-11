#!/usr/bin/env bash
# test_loop.sh — runs N cold-start cycles and verifies MDOX profile ordering.
#
# For each trial:
#   1. Invoke the function (cold start if needed)
#   2. Verify Redis has a `started:<podUID>` key with profile metadata
#   3. Delete the pod (triggers SIGTERM → JVM dumps MDOX → wrapper pushes to Redis)
#   4. Wait for pod to fully terminate
#   5. Verify Redis has `terminated:<podUID>` and an MDOX artifact
#   6. On trial 2+, verify the new pod loaded the previous profile
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
ARTIFACT_KEY="artifact:${FN_NAME}:${FN_VERSION}"

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

# ── Pre-loop: force a fresh pod so trial 1 starts clean ──────────────────────
log "PRE-LOOP: cycling pod to ensure trial 1 starts fresh..."
kubectl delete pod -n "${FN_NAMESPACE}" -l "faas_function=${FN_NAME}" \
  --grace-period=20 2>/dev/null || true
kubectl wait --for=delete pod \
  -n "${FN_NAMESPACE}" -l "faas_function=${FN_NAME}" \
  --timeout=40s 2>/dev/null || true
log "PRE-LOOP: waiting for replacement pod..."
sleep 8

# Check if there's an existing profile in Redis
EXISTING_SIZE=$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" STRLEN "${ARTIFACT_KEY}" 2>/dev/null || echo "0")
log "Baseline: existing artifact size=${EXISTING_SIZE} bytes in Redis"
echo ""

PREV_PROFILE_SIZE=0

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

  POD_UID=$(echo "${RESPONSE}"        | jq -r '.pod'            2>/dev/null || echo "unknown")
  PROFILE_HASH=$(echo "${RESPONSE}"   | jq -r '.profile_hash'   2>/dev/null || echo "none")
  PROFILE_SIZE=$(echo "${RESPONSE}"   | jq -r '.profile_size'   2>/dev/null || echo "0")
  PROFILE_LOADED=$(echo "${RESPONSE}" | jq -r '.profile_loaded' 2>/dev/null || echo "false")
  RUNSEQ=$(echo "${RESPONSE}"         | jq -r '.runseq'         2>/dev/null || echo "?")
  log "pod_uid=${POD_UID}  profile_hash=${PROFILE_HASH}  profile_size=${PROFILE_SIZE}  profile_loaded=${PROFILE_LOADED}  runseq=${RUNSEQ}"

  # ── 2. Verify started key ──────────────────────────────────────────────────
  STARTED=$(rget "started:${POD_UID}")
  if [ -z "${STARTED}" ]; then
    log "FAIL: no started key for pod ${POD_UID}"
    FAIL=$((FAIL+1))
    RESULTS+=("trial=${i} FAIL reason=no_started_key pod=${POD_UID}")
    continue
  fi
  log "started key present: ${STARTED}"

  # ── 2b. Verify profile was loaded on trial 2+ ─────────────────────────────
  if [ "${i}" -gt 1 ] && [ "${PREV_PROFILE_SIZE}" -gt 0 ]; then
    if [ "${PROFILE_LOADED}" != "true" ]; then
      log "FAIL: trial ${i} should have loaded profile from previous run (prev_size=${PREV_PROFILE_SIZE})"
      TRIAL_PASS=false
    else
      log "profile loaded from previous run: hash=${PROFILE_HASH} size=${PROFILE_SIZE}"
    fi
  fi

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

  # Verify MDOX artifact was pushed to Redis (stored as base64)
  NEW_ARTIFACT_B64_LEN=$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" STRLEN "${ARTIFACT_KEY}" 2>/dev/null || echo "0")
  if [ "${NEW_ARTIFACT_B64_LEN}" -eq 0 ]; then
    log "FAIL: artifact key missing or empty after termination"
    TRIAL_PASS=false
  else
    # base64 inflates ~33%, so real binary size ≈ b64_len * 3/4
    APPROX_BINARY_SIZE=$(( NEW_ARTIFACT_B64_LEN * 3 / 4 ))
    log "artifact base64_len=${NEW_ARTIFACT_B64_LEN}  approx_binary=${APPROX_BINARY_SIZE} bytes in Redis"
    # An MDOX profile header is ~30 bytes minimum; base64 of that is ~44+ chars
    if [ "${NEW_ARTIFACT_B64_LEN}" -lt 40 ]; then
      # Could be "__EMPTY__" marker (first trial with no prior profile)
      RAW_VAL=$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" --raw GET "${ARTIFACT_KEY}" 2>/dev/null || true)
      if [ "${RAW_VAL}" = "__EMPTY__" ]; then
        log "artifact is __EMPTY__ marker (first run, no JIT data yet)"
      else
        log "WARN: artifact suspiciously small (${NEW_ARTIFACT_B64_LEN} chars b64), may not be valid MDOX"
      fi
    fi
  fi

  # Check metadata key
  META=$(rget "meta:${ARTIFACT_KEY}")
  if [ -n "${META}" ]; then
    META_SIZE=$(echo "${META}" | jq -r '.mdox_size // 0' 2>/dev/null || echo "0")
    META_WRITER=$(echo "${META}" | jq -r '.last_writer_pod // "?"' 2>/dev/null || echo "?")
    log "meta: writer=${META_WRITER} mdox_size=${META_SIZE}"
  fi

  PREV_PROFILE_SIZE="${NEW_ARTIFACT_B64_LEN}"

  if ${TRIAL_PASS}; then
    log "Trial ${i}: PASS"
    PASS=$((PASS+1))
    RESULTS+=("trial=${i} PASS pod=${POD_UID} runseq=${RUNSEQ} profile_hash=${PROFILE_HASH} profile_loaded=${PROFILE_LOADED} artifact_b64_len=${NEW_ARTIFACT_B64_LEN}")
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
