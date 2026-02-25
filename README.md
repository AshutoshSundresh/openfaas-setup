# OpenFaaS JVM Profile Artifact Demo

Local infra demo that proves pull-before-start and push-on-termination ordering for JVM profile artifacts, using OpenFaaS on Kubernetes and Redis as the artifact store.

Each function instance:
1. **Pulls** an artifact from Redis before `java` starts
2. Runs a minimal JVM HTTP handler
3. On **SIGTERM**, pushes an updated artifact to Redis before the process is killed

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/) or [k3d](https://k3d.io/)
- [faas-cli](https://docs.openfaas.com/cli/install/)
- `jq`, `redis-cli` (on the host running the test script)

---

## Setup

### 1. Create a local cluster

```bash
# kind
kind create cluster --name openfaas

# or k3d
k3d cluster create openfaas
```

### 2. Install OpenFaaS

```bash
kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml

helm repo add openfaas https://openfaas.github.io/faas-netes/
helm repo update
helm upgrade --install openfaas openfaas/openfaas \
  --namespace openfaas \
  --set functionNamespace=openfaas-fn \
  --set generateBasicAuth=true
```

Retrieve the admin password and log in:

```bash
PASSWORD=$(kubectl -n openfaas get secret basic-auth -o jsonpath='{.data.basic-auth-password}' | base64 --decode)
echo $PASSWORD | faas-cli login --username admin --password-stdin --gateway http://127.0.0.1:8080
```

### 3. Deploy Redis

```bash
kubectl apply -f k8s/redis.yaml
```

### 4. Build and deploy the function

```bash
# Build the image (runs inside the cluster's Docker context for kind/k3d)
docker build -t profile-fn:latest ./fn

# For kind: load the image into the cluster (skips a registry)
kind load docker-image profile-fn:latest --name openfaas

# Deploy via OpenFaaS
faas-cli deploy -f stack.yml

# Patch the Deployment to add grace period + POD_UID downward API
kubectl patch deployment profile-fn -n openfaas-fn \
  --patch-file k8s/function-patch.yaml
```

---

## Running the demo

Open two port-forward terminals and leave them running:

```bash
# Terminal 1 — OpenFaaS gateway
kubectl port-forward -n openfaas svc/gateway 8080:8080

# Terminal 2 — Redis (for test script and manual inspection)
kubectl port-forward -n openfaas svc/redis 6379:6379
```

Run the test loop:

```bash
chmod +x scripts/test_loop.sh
TRIALS=20 ./scripts/test_loop.sh
```

The script exits `0` if every trial passes, `1` otherwise.

**Trial 1 note:** Redis has no artifact yet on a fresh cluster. The wrapper logs `ARTIFACT_MISSING`, seeds a default payload (counter=0), and the first push writes counter=1. This is expected — the script detects the pre-existing counter before the loop starts and uses it as the baseline, so trial 1 passes like any other.

Expected output per trial:

```
[...] No existing artifact — trial 1 will seed Redis from default (counter=0 → 1)

[...] ══ Trial 1/20 ══════
[...] Invoking profile-fn...
[...] pod_uid=abc123  artifact_hash=3f9a1c  runseq=1
[...] started key present: {"pod":"abc123","started_ms":...}
[...] Deleting pod profile-fn-xxxx (grace=20s)...
[...] Waiting for pod termination...
[...] terminated key present: {"pod":"abc123","terminated_ms":...}
[...] artifact counter=1 (expected 1)  last_writer=abc123
[...] Trial 1: PASS
```

---

## Manual inspection

```bash
# Last written artifact
redis-cli GET artifact:profile-fn:v1

# Per-pod start record
redis-cli GET started:<podUID>

# Per-pod termination record
redis-cli GET terminated:<podUID>

# Run sequence counter
redis-cli GET runseq:profile-fn:v1
```

---

## What the ordering proof looks like

| Log event | Source | Meaning |
|---|---|---|
| `PRE_PULL_DONE` | `entrypoint.sh` | Artifact on disk before JVM starts |
| `JAVA_STARTED` | `entrypoint.sh` + Java | JVM is up, artifact hash logged |
| `JAVA_SIGTERM` | Java shutdown hook | JVM received termination signal |
| `TERM_HANDLER_START` | `entrypoint.sh` | Wrapper caught SIGTERM, starting push |
| `POST_PUSH_DONE` | `entrypoint.sh` | Artifact pushed to Redis |

From trial 2 onward, each cold start reads the artifact written by the previous instance. The test script verifies `counter == prev + 1` on every trial — that monotonic increment is the chain-of-custody proof. Trial 1 bootstraps the chain from a default payload, which is expected and not a failure.

---

## Project layout

```
.
├── fn/
│   ├── Dockerfile          # multi-stage: Maven builder + JRE-alpine runtime
│   ├── entrypoint.sh       # wrapper: pull → start JVM → SIGTERM trap → push
│   ├── pom.xml
│   └── src/main/java/com/demo/ProfileFunction.java
├── k8s/
│   ├── redis.yaml          # Redis Deployment + Service (openfaas namespace)
│   └── function-patch.yaml # adds terminationGracePeriodSeconds + POD_UID env
├── scripts/
│   └── test_loop.sh        # N-trial invoke/kill/verify harness
└── stack.yml               # faas-cli deploy spec
```

---

## Phase 2 (next step)

Once this is stable, move the pull/push out of the app container into Kubernetes lifecycle primitives:

- **initContainer** pulls the artifact into a shared `emptyDir` at `/profiles`
- **preStop hook** or sidecar pushes the artifact on termination

See `k8s/function-patch.yaml` for the patch point — the initContainer and preStop entries go in the same `spec.template.spec` block.
