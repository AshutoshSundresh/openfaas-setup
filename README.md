# OpenFaaS JVM Profile Artifact Demo

Local infra demo that proves pull-before-start and push-on-termination ordering for JVM profile artifacts, using OpenFaaS on Kubernetes and Redis as the artifact store.

Each function instance:
1. **Pulls** an artifact from Redis before `java` starts
2. Runs a minimal JVM HTTP handler
3. On **SIGTERM**, pushes an updated artifact to Redis before the process is killed

---

## Prerequisites

Docker, kubectl, kind, helm, faas-cli, jq, and redis-cli must all be on your PATH.

### Windows (Scoop — run in PowerShell)

```powershell
# Install Scoop if you don't have it
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
irm get.scoop.sh | iex

# Core tools
scoop install kind helm jq redis

# faas-cli
scoop bucket add extras
scoop install faas-cli
```

Install [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/) separately and start it before proceeding. kubectl ships with Docker Desktop; if you need it standalone: `scoop install kubectl`.

### macOS (Homebrew)

```bash
brew install kind helm jq redis faas-cli
brew install --cask docker   # Docker Desktop
```

### Linux

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# kind
curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
chmod +x kind && sudo mv kind /usr/local/bin/

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# faas-cli
curl -sSL https://cli.openfaas.com | sudo sh

# jq and redis-cli
sudo apt-get install -y jq redis-tools   # Debian/Ubuntu
# sudo dnf install -y jq redis            # Fedora/RHEL
```

---

## Setup

### 1. Create a local cluster

**Windows:** kind fails on Windows Git Bash due to a cgroup issue. Use Docker Desktop's built-in Kubernetes instead: open Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply & Restart. No CLI command needed.

**macOS / Linux:**

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

### 3. Deploy Redis

```bash
kubectl apply -f k8s/redis.yaml
```

### 4. Deploy the function

`stack.yml` references a pre-built public image (`asundresh/profile-fn:latest`) so you can deploy straight away without building anything:

```bash
# Log in to the OpenFaaS gateway (keep the port-forward from step 2 running)
PASSWORD=$(kubectl -n openfaas get secret basic-auth -o jsonpath='{.data.basic-auth-password}' | base64 --decode)
echo $PASSWORD | faas-cli login --username admin --password-stdin --gateway http://127.0.0.1:8080

# Deploy — must be run from the repo root
faas-cli deploy -f stack.yml

# Patch the Deployment to add grace period + POD_UID downward API
kubectl patch deployment profile-fn -n openfaas-fn \
  --patch-file k8s/function-patch.yaml
```

**If you want to modify the function and push your own image:**

```bash
docker build -t <your-dockerhub-username>/profile-fn:latest ./fn
docker push <your-dockerhub-username>/profile-fn:latest
```

Then update the `image:` line in `stack.yml` to match and redeploy. OpenFaaS CE only accepts public registry images, so the repository must be public on Docker Hub (or another public registry).

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
