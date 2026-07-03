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
  # Uninstall ingress-nginx FIRST: deleting its LoadBalancer Service is what makes
  # AWS delete the NLB. That NLB is not in Terraform state, so if it survives it
  # both accrues cost AND blocks VPC/subnet deletion during terraform destroy.
  helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
  helm uninstall cert-manager  -n cert-manager  2>/dev/null || true
  # Give AWS a moment to actually tear the NLB down before we destroy the VPC.
  echo "Waiting for the NLB to be deprovisioned..."
  for _ in $(seq 1 18); do
    kubectl get svc ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1 || break
    sleep 10
  done
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

  # 1b. Storage ---------------------------------------------------------------
  # The aws-ebs-csi-driver addon was installed by Terraform above. Make gp3 the
  # default StorageClass so Postgres' PVC binds to a real EBS volume. EKS may
  # ship gp2 as default (dead in-tree provisioner) — demote it to avoid two
  # defaults, which would leave the PVC unscheduled.
  log "1b. Default StorageClass -> gp3 (EBS CSI)"
  kubectl apply -f kubernetes/platform/storage/gp3-storageclass.yaml
  kubectl patch storageclass gp2 \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
    2>/dev/null || true

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

  # 2b. Ingress controller (nginx) --------------------------------------------
  # Its LoadBalancer Service makes AWS provision an NLB automatically. --wait
  # blocks on the controller pods (not the LB — see 2d for that).
  log "2b. ingress-nginx (provisions the public NLB)"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update ingress-nginx >/dev/null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace --wait --timeout 5m \
    -f kubernetes/platform/ingress-nginx/values.yaml

  # 2c. cert-manager + ClusterIssuers -----------------------------------------
  log "2c. cert-manager (crds.enabled brings the ClusterIssuer/Certificate types)"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true --wait --timeout 5m
  # Pure config the running cert-manager reads — not a pod, hence kubectl apply.
  kubectl apply -f kubernetes/platform/cert-manager/clusterissuer.yaml

  # 2d. Resolve the NLB -> nip.io host ----------------------------------------
  # The NLB is provisioned asynchronously: its hostname lands on the Service a bit
  # after helm returns, and its DNS takes a further moment to resolve to an IP.
  # nip.io maps <ip>.nip.io -> <ip>, so we build the host from the resolved IP.
  log "2d. Resolve NLB address -> nip.io host"
  LB_HOST=""
  for _ in $(seq 1 30); do
    LB_HOST="$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [ -n "$LB_HOST" ] && break
    sleep 10
  done
  [ -n "$LB_HOST" ] || { echo "ERROR: NLB hostname never appeared on the Service" >&2; exit 1; }

  LB_IP=""
  for _ in $(seq 1 30); do
    # `|| true`: until DNS propagates, getent exits non-zero; under `set -o pipefail`
    # that failure would propagate through the assignment and `set -e` would kill the
    # script mid-loop — before we ever reach the sleep/retry. Swallow it so we retry.
    LB_IP="$(getent hosts "$LB_HOST" | awk '{print $1; exit}' || true)"
    [ -n "$LB_IP" ] && break
    sleep 10
  done
  [ -n "$LB_IP" ] || { echo "ERROR: NLB DNS ($LB_HOST) did not resolve to an IP" >&2; exit 1; }

  HOST="${LB_IP}.nip.io"
  echo "Public host: https://$HOST"

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
  kubectl apply -f kubernetes/apps/backend/configmap.yaml
  sed "s|<ECR_REPO_URL>:<SHA>|$ECR/staging-backend:$SHA|g" \
    kubernetes/apps/backend/deployment.yaml | kubectl apply -f -
  kubectl apply -f kubernetes/apps/backend/service.yaml
  kubectl apply -f kubernetes/apps/backend/hpa.yaml

  sed "s|<ECR_REPO_URL>:<SHA>|$ECR/staging-frontend:$SHA|g" \
    kubernetes/apps/frontend/deployment.yaml | kubectl apply -f -
  kubectl apply -f kubernetes/apps/frontend/service.yaml

  kubectl rollout status deployment/backend  --timeout=180s
  kubectl rollout status deployment/frontend --timeout=180s

  # 5b. Ingress + TLS ---------------------------------------------------------
  # Substitute the resolved nip.io host, then let cert-manager's ingress-shim see
  # the annotation and issue the cert into the kubeplay-tls Secret automatically.
  log "5b. Ingress + TLS (host: $HOST)"
  sed "s|<HOST>|$HOST|g" kubernetes/apps/ingress.yaml | kubectl apply -f -
  echo "Waiting for Let's Encrypt to issue the certificate..."
  # The auto-created Certificate is named after the secretName (kubeplay-tls).
  kubectl wait --for=condition=Ready certificate/kubeplay-tls --timeout=180s \
    || kubectl describe certificate kubeplay-tls || true

  # 6. Verify -----------------------------------------------------------------
  log "6. Status"
  kubectl get pods
  kubectl get hpa
  cat <<EOF

Deploy complete. The app is live over HTTPS at:

  https://$HOST

NOTE: we start on Let's Encrypt STAGING, so the browser shows a red
"not private" warning — that is expected. The cert is real, just signed by an
untrusted staging CA. Flip the annotation in kubernetes/apps/ingress.yaml to
'letsencrypt-prod' and re-run to get a trusted 🔒.

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
