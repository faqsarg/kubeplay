#!/usr/bin/env bash
# deploy.sh — bring the kubeplay app up on a fresh staging cluster (Phase 3).
#
# Mirrors docs/runbooks/deploy.md, automated. Idempotent where possible, so it is
# safe to re-run (helm upgrade --install, kubectl apply, terraform apply are no-ops
# when nothing changed). This script is the seed of the Phase 5 CI/CD pipeline.
#
# Usage:
#   ./scripts/deploy.sh            # full deploy (terraform + cluster workloads)
#   ./scripts/deploy.sh teardown   # tear down ephemeral layer (bootstrap is NEVER touched)
#
# Requires locally: terraform, aws, kubectl, helm, docker (+ valid AWS credentials).
set -euo pipefail

# ---- config -----------------------------------------------------------------
REGION="eu-west-1"
CLUSTER="staging-eks"
ACCOUNT_ID="915170001562"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
STAGING="terraform/environments/staging"
PG_CHART_VERSION="16.7.27"   # -> PostgreSQL 17.6 (newest image left on bitnamilegacy)

# always run from the repo root, no matter where the script is invoked from
cd "$(dirname "$0")/.."

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

# ---- teardown ---------------------------------------------------------------
teardown() {
  log "Teardown (ephemeral layer only — bootstrap/ stays alive)"
  helm uninstall postgres 2>/dev/null || true
  # Helm retains the StatefulSet PVC on purpose; that PVC is a real EBS volume NOT
  # tracked by Terraform. Delete it BEFORE destroy or it becomes an orphan accruing cost.
  kubectl delete pvc -l app.kubernetes.io/instance=postgres --ignore-not-found
  terraform -chdir="$STAGING" destroy -auto-approve
  log "Done. bootstrap/ (S3 state + AWS secret) was intentionally left untouched."
}

# ---- deploy -----------------------------------------------------------------
deploy() {
  # 0. Infrastructure ---------------------------------------------------------
  log "0a. Bootstrap (durable layer; no-op if already applied)"
  terraform -chdir=bootstrap init -input=false
  terraform -chdir=bootstrap apply -auto-approve

  log "0b. Staging cluster (this is the slow/expensive one)"
  terraform -chdir="$STAGING" init -input=false
  terraform -chdir="$STAGING" apply -auto-approve

  log "0c. Point kubectl at the new cluster"
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
  kubectl get nodes

  log "0d. Log docker in to ECR"
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR"

  SHA="$(git rev-parse --short HEAD)"
  echo "Image tag (git SHA): $SHA"

  # 1. metrics-server ---------------------------------------------------------
  log "1. metrics-server (HPA needs CPU metrics)"
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s

  # 2. ESO --------------------------------------------------------------------
  log "2. External Secrets Operator + secret sync"
  ROLE_ARN="$(terraform -chdir="$STAGING" output -raw eso_irsa_role_arn)"
  echo "eso_irsa role: $ROLE_ARN"

  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update external-secrets >/dev/null
  # --wait blocks until ALL ESO deployments (controller, webhook, cert-controller) are ready.
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace --wait --timeout 5m \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"
  # The validating webhook must have live endpoints before a (Cluster)SecretStore can be
  # created — otherwise: "no endpoints available for service external-secrets-webhook".
  kubectl wait --for=condition=Available deployment --all \
    -n external-secrets --timeout=180s

  # Belt-and-suspenders: retry the applies until the webhook is actually serving.
  for _ in $(seq 1 12); do
    if kubectl apply -f kubernetes/apps/eso/secretstore.yaml \
       && kubectl apply -f kubernetes/apps/eso/externalsecret.yaml; then
      break
    fi
    echo "  webhook not serving yet, retrying in 5s..."
    sleep 5
  done

  echo "Waiting for ESO to sync the postgres-credentials Secret..."
  synced=false
  for _ in $(seq 1 30); do
    if kubectl get secret postgres-credentials -n default >/dev/null 2>&1; then
      synced=true; break
    fi
    sleep 5
  done
  if [ "$synced" != true ]; then
    echo "ERROR: Secret not synced after 150s — check IRSA wiring:" >&2
    kubectl describe externalsecret postgres-credentials -n default >&2 || true
    kubectl logs -n external-secrets deploy/external-secrets --tail=30 >&2 || true
    exit 1
  fi
  echo "Secret synced ✔"

  # 3. PostgreSQL -------------------------------------------------------------
  log "3. PostgreSQL via Helm (release MUST be named 'postgres')"
  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
  helm repo update bitnami >/dev/null
  helm upgrade --install postgres bitnami/postgresql \
    --version "$PG_CHART_VERSION" \
    -f kubernetes/apps/postgres/values.yaml
  kubectl rollout status statefulset/postgres-postgresql --timeout=300s

  # 4. Build + push images ----------------------------------------------------
  log "4. Build + push images to ECR (tag: $SHA)"
  docker build -t "$ECR/staging-backend:$SHA"  apps/backend
  docker push      "$ECR/staging-backend:$SHA"
  docker build -t "$ECR/staging-frontend:$SHA" apps/frontend
  docker push      "$ECR/staging-frontend:$SHA"

  # 5. Apply app manifests (substitute the image placeholder) -----------------
  log "5. Apply backend + frontend manifests"
  sed "s|<ECR_REPO_URL>:<SHA>|$ECR/staging-backend:$SHA|g" \
    kubernetes/apps/backend/deployment.yaml | kubectl apply -f -
  kubectl apply -f kubernetes/apps/backend/service.yaml
  kubectl apply -f kubernetes/apps/backend/hpa.yaml

  sed "s|<ECR_REPO_URL>:<SHA>|$ECR/staging-frontend:$SHA|g" \
    kubernetes/apps/frontend/deployment.yaml | kubectl apply -f -
  kubectl apply -f kubernetes/apps/frontend/service.yaml

  kubectl rollout status deployment/backend  --timeout=180s
  kubectl rollout status deployment/frontend --timeout=180s

  # 6. Verify -----------------------------------------------------------------
  log "6. Status"
  kubectl get pods
  kubectl get hpa
  cat <<EOF

Deploy complete. Smoke-test the API with a port-forward (Ingress is Phase 4):

  kubectl port-forward svc/backend 8080:8080 &
  curl localhost:8080/api/items

Tear everything down at the end of the session with:

  ./scripts/deploy.sh teardown
EOF
}

# ---- entrypoint -------------------------------------------------------------
case "${1:-deploy}" in
  deploy)   deploy ;;
  teardown) teardown ;;
  *) echo "usage: $0 [deploy|teardown]" >&2; exit 1 ;;
esac
