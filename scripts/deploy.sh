#!/usr/bin/env bash
# deploy.sh — bring the kubeplay app up on a fresh staging cluster (Phase 3).
#
# Mirrors docs/runbooks/deploy.md, automated. Idempotent where possible, so it is
# safe to re-run (helm upgrade --install, kubectl apply, terraform apply are no-ops
# when nothing changed). This script is the seed of the Phase 5 CI/CD pipeline.
#
# Usage:
#   ./scripts/deploy.sh              # deploy staging only (lean default for study sessions)
#   ./scripts/deploy.sh --with-prod  # also provision the `production` namespace + its stack
#   ./scripts/deploy.sh teardown     # tear down ephemeral layer (bootstrap is NEVER touched)
#
# production is opt-in: a normal session runs one env; --with-prod brings up the second
# (own namespace, Postgres, ESO secret, and Argo apps) only when demoing a release/promotion.
# teardown always cleans BOTH envs regardless of the flag, so nothing is ever orphaned.
#
# Requires locally: terraform, aws, kubectl, helm (+ valid AWS credentials).
# (No docker: images are built by CI, not here — the cluster pulls them from ECR.)
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
  # Same for production (if --with-prod ever brought it up). Unconditional + idempotent
  # so a plain `teardown` never leaves a prod EBS volume orphaned.
  helm uninstall postgres -n production 2>/dev/null || true
  kubectl delete pvc -l app.kubernetes.io/instance=postgres -n production --ignore-not-found
  terraform -chdir="$STAGING" destroy -auto-approve
  log "Done. bootstrap/ (S3 state + AWS secret) was intentionally left untouched."
}

# ---- production data stack (only with --with-prod) --------------------------
# Mirror of staging's data layer (ESO Secret + Postgres) but in the `production`
# namespace, with its own credentials. Reuses the same values.yaml (namespace-agnostic)
# and the shared cluster-wide ESO controller + ClusterSecretStore from step 2.
deploy_prod_data() {
  log "3p. Production data stack (namespace + ESO Secret + Postgres)"
  kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -

  # Materialize postgres-credentials in `production` from kubeplay/production/postgres.
  kubectl apply -f kubernetes/apps/eso/externalsecret-prod.yaml

  echo "Waiting for ESO to sync the production postgres-credentials Secret..."
  synced=false
  for _ in $(seq 1 30); do
    if kubectl get secret postgres-credentials -n production >/dev/null 2>&1; then
      synced=true; break
    fi
    sleep 5
  done
  if [ "$synced" != true ]; then
    echo "ERROR: prod Secret not synced after 150s:" >&2
    kubectl describe externalsecret postgres-credentials -n production >&2 || true
    exit 1
  fi
  echo "Prod Secret synced ✔"

  # Postgres in `production`: own release (namespace-scoped, so 'postgres' doesn't
  # collide with staging's), own EBS volume. The release MUST be named 'postgres' so
  # its Service is postgres-postgresql — the host the backend resolves within its ns.
  helm upgrade --install postgres bitnami/postgresql \
    --namespace production \
    --version "$PG_CHART_VERSION" \
    -f kubernetes/apps/postgres/values.yaml
  kubectl rollout status statefulset/postgres-postgresql -n production --timeout=300s
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

  # 1c. Monitoring (kube-prometheus-stack) ------------------------------------
  # Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics in
  # one umbrella chart. Placed right after the StorageClass (1b) on purpose:
  # Prometheus and Grafana provision PVCs, so the default gp3 class must already
  # exist or their pods stay Pending — the same dependency Postgres has. This is
  # platform, so deploy.sh installs it imperatively (Argo only owns the apps).
  log "1c. kube-prometheus-stack (Prometheus + Grafana + Alertmanager)"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  # --wait blocks until every component is Ready; the chart ships many CRDs and
  # Deployments, so give it a generous timeout.
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace --wait --timeout 10m \
    -f kubernetes/platform/monitoring/values.yaml

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
       && kubectl apply -f kubernetes/apps/eso/externalsecret-staging.yaml; then
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

  # 3p. Production data stack (opt-in) ----------------------------------------
  # Bring up prod's data BEFORE its Argo apps so backend-prod finds Postgres + the
  # Secret on first sync instead of crash-looping until they appear.
  if $WITH_PROD; then
    deploy_prod_data
  fi

  # 3b. ArgoCD ----------------------------------------------------------------
  # The bootstrap paradox: Argo deploys our apps declaratively from git, but Argo
  # itself can't self-install — so deploy.sh (the imperative layer) installs it once.
  # From here on, Argo owns backend/frontend; deploy.sh only bootstraps the platform.
  log "3b. ArgoCD (GitOps controller — will reconcile the apps from git)"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd --create-namespace --wait --timeout 5m

  # Register the Application CRs (one-time bootstrap). From here Argo watches git
  # and reconciles the apps itself — no kubectl apply of the apps needed. Staging
  # apps always; prod apps only when --with-prod (else backend-prod would crash-loop
  # against a production namespace with no Postgres/Secret).
  kubectl apply -f kubernetes/argocd/backend-staging-app.yaml \
                -f kubernetes/argocd/frontend-staging-app.yaml
  if $WITH_PROD; then
    kubectl apply -f kubernetes/argocd/backend-prod-app.yaml \
                  -f kubernetes/argocd/frontend-prod-app.yaml
  fi

  # 4. Apps are owned by Argo now ---------------------------------------------
  # Building/pushing images and deploying backend/frontend is no longer done here.
  # The CD pipeline (.github/workflows/deploy-staging.yml) builds + pushes on merge
  # to main and commits the image tag; ArgoCD (installed in 3b) reconciles it from
  # git. ECR is durable, so main's kustomization always pins a real, existing tag —
  # Argo pulls and rolls out on its own, a couple of minutes after this script ends.

  # 5. Ingress + TLS ----------------------------------------------------------
  # Substitute the resolved nip.io host, then let cert-manager's ingress-shim see
  # the annotation and issue the cert into the kubeplay-tls Secret automatically.
  log "5. Ingress + TLS (host: $HOST)"
  sed "s|<HOST>|$HOST|g" kubernetes/apps/ingress-staging.yaml | kubectl apply -f -
  echo "Waiting for Let's Encrypt to issue the certificate..."
  # The auto-created Certificate is named after the secretName (kubeplay-tls).
  kubectl wait --for=condition=Ready certificate/kubeplay-tls -n default --timeout=180s \
    || kubectl describe certificate kubeplay-tls -n default || true

  # 5p. Production Ingress + TLS (opt-in) -------------------------------------
  # Same shared NLB; host prefixed `prod.` (nip.io resolves it to the same IP), so
  # nginx routes by Host header to the production-namespace Services. Its cert is a
  # separate kubeplay-tls Secret issued into the production namespace.
  if $WITH_PROD; then
    log "5p. Production Ingress + TLS (host: prod.$HOST)"
    sed "s|<HOST>|$HOST|g" kubernetes/apps/ingress-prod.yaml | kubectl apply -f -
    kubectl wait --for=condition=Ready certificate/kubeplay-tls -n production --timeout=180s \
      || kubectl describe certificate kubeplay-tls -n production || true
    echo "Production host: https://prod.$HOST"
  fi

  # 6. Verify -----------------------------------------------------------------
  log "6. Status"
  kubectl get pods
  kubectl get hpa
  cat <<EOF

Deploy complete. The app is live over HTTPS at:

  https://$HOST

NOTE: we start on Let's Encrypt STAGING, so the browser shows a red
"not private" warning — that is expected. The cert is real, just signed by an
untrusted staging CA. Flip the annotation in kubernetes/apps/ingress-staging.yaml to
'letsencrypt-prod' and re-run to get a trusted 🔒.

Tear everything down at the end of the session with:

  ./scripts/deploy.sh teardown
EOF
}

# ---- entrypoint -------------------------------------------------------------
# Parse a command (deploy|teardown) and an optional --with-prod flag, in any order.
CMD="deploy"
WITH_PROD=false
for arg in "$@"; do
  case "$arg" in
    deploy|teardown) CMD="$arg" ;;
    --with-prod)     WITH_PROD=true ;;
    *) echo "usage: $0 [deploy|teardown] [--with-prod]" >&2; exit 1 ;;
  esac
done

case "$CMD" in
  deploy)   deploy ;;
  teardown) teardown ;;
esac
