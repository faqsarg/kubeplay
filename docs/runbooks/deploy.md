# Runbook — Application deploy (Phase 3)

Project strategy: **apply-then-destroy**. The cluster is destroyed at the end of each
session to avoid paying for the EKS control plane. This runbook is the procedure to bring
the app up **from scratch on a freshly created cluster**, with nothing kept in memory.

> Order matters. Each step depends on the previous one existing (see the "why" notes).

---

## 0. Prerequisites

```bash
# Durable layer (one-time; survives destroy): S3 backend + AWS Secrets Manager secret
# + ESO IRSA prerequisites. Re-run only after changing bootstrap/ (e.g. the random provider).
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply

# Cluster up (creates VPC, EKS, ECR, the eso_irsa role)
cd terraform/environments/staging && terraform apply

# Point kubeconfig at the new cluster
aws eks update-kubeconfig --region eu-west-1 --name staging-eks

# Verify access
kubectl get nodes
```

Variables used below (adjust the account id if it changes):

```bash
export AWS_REGION=eu-west-1
export ECR=915170001562.dkr.ecr.eu-west-1.amazonaws.com
export SHA=$(git rev-parse --short HEAD)

# Log in to ECR so we can push
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR
```

---

## 1. metrics-server  *(so the HPA has CPU metrics)*

EKS does **not** ship metrics-server by default. Without it, the backend HPA stays at
`<unknown>/70%` and never scales.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

---

## 2. Secret `postgres-credentials` via ESO  *(BEFORE Postgres and the backend)*

The Secret is **not** created by hand. The source of truth is AWS Secrets Manager
(`kubeplay/staging/postgres`, created in the `bootstrap/` Terraform layer); the External
Secrets Operator (ESO) reads it and materializes a native K8s Secret named
`postgres-credentials` in the `default` namespace. Two consumers read that Secret: the
Postgres chart (`existingSecret`) and the backend Deployment (`secretKeyRef`). If it does
not exist, both pods get stuck in `CreateContainerConfigError`.

ESO authenticates to AWS via IRSA — no static keys. The `eso_irsa` role (least privilege:
`GetSecretValue` on that one secret) is created by `terraform apply`; grab its ARN:

```bash
ROLE_ARN=$(terraform -chdir=terraform/environments/staging output -raw eso_irsa_role_arn)
```

Install ESO into its own namespace, annotating its ServiceAccount with the role ARN. The
SA name+namespace MUST be `external-secrets`/`external-secrets` — that is exactly what the
role's trust policy pins via the OIDC `sub` claim.

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"

# wait for the operator (and its CRDs) to be ready
kubectl rollout status deployment/external-secrets -n external-secrets
```

Apply the connection config + the recipe, then confirm ESO created the Secret:

```bash
kubectl apply -f kubernetes/apps/eso/secretstore.yaml      # ClusterSecretStore (cluster-scoped)
kubectl apply -f kubernetes/apps/eso/externalsecret.yaml   # ExternalSecret in default

# the ExternalSecret should report SecretSynced; the Secret must exist BEFORE Postgres boots
kubectl get externalsecret postgres-credentials -n default
kubectl get secret postgres-credentials -n default
```

- `password` → app user `kubeplay` (the backend's `DATABASE_URL` and the chart's `userPasswordKey`)
- `postgres-password` → `postgres` superuser (chart-internal only)

---

## 3. PostgreSQL via Helm  *(before the backend: the backend connects to it)*

The release **must** be named `postgres` → it generates the `postgres-postgresql` Service,
which is exactly the host hardcoded in the backend's `DATABASE_URL`.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# chart 16.7.27 → PostgreSQL 17.6 (newest image still on bitnamilegacy; see values.yaml).
# Pin the version: the latest chart defaults to a broken bitnami/postgresql:latest.
helm install postgres bitnami/postgresql \
  --version 16.7.27 \
  -f kubernetes/apps/postgres/values.yaml

# wait for the pod to become Ready
kubectl rollout status statefulset/postgres-postgresql
```

---

## 4. Build + push images to ECR

One repo per image: `staging-backend` and `staging-frontend`.

```bash
# Backend
docker build -t $ECR/staging-backend:$SHA apps/backend
docker push $ECR/staging-backend:$SHA

# Frontend
docker build -t $ECR/staging-frontend:$SHA apps/frontend
docker push $ECR/staging-frontend:$SHA
```

---

## 5. Apply manifests (with the image substituted)

The manifests use `image: <ECR_REPO_URL>:<SHA>` as a placeholder. Until CI/CD exists
(Phase 5), substitute it by hand with `sed` and apply via stdin:

```bash
# Backend (Deployment + Service + HPA)
sed "s|<ECR_REPO_URL>:<SHA>|$ECR/staging-backend:$SHA|g" \
  kubernetes/apps/backend/deployment.yaml | kubectl apply -f -
kubectl apply -f kubernetes/apps/backend/service.yaml
kubectl apply -f kubernetes/apps/backend/hpa.yaml

# Frontend (Deployment + Service)
sed "s|<ECR_REPO_URL>:<SHA>|$ECR/staging-frontend:$SHA|g" \
  kubernetes/apps/frontend/deployment.yaml | kubectl apply -f -
kubectl apply -f kubernetes/apps/frontend/service.yaml
```

---

## 6. Verify

```bash
kubectl get pods                 # backend, frontend and postgres Running/Ready
kubectl get hpa                  # backend TARGETS should not be <unknown>
kubectl logs deploy/backend      # should connect to Postgres without errors

# internal smoke test (before we have an Ingress)
kubectl port-forward svc/backend 8080:8080 &
curl localhost:8080/api/items
```

> Public access (ALB + Ingress + DNS) and the `/api/*`→backend, `/`→frontend routing
> belong to **Phase 4**. Until then, test with `port-forward`.

---

## Teardown (at the end of the session)

```bash
helm uninstall postgres
# Helm does NOT delete the StatefulSet's PVC (it retains it on purpose). That PVC is backed
# by a real EBS volume that Terraform does NOT know about (the EBS CSI driver created it,
# not Terraform). If you skip this, you leave an ORPHAN EBS volume accruing cost after destroy.
kubectl delete pvc -l app.kubernetes.io/instance=postgres

cd terraform/environments/staging && terraform destroy
```

> The Secret and the manifests live in the cluster: they go away with `terraform destroy`.
> That is why they must be recreated (steps 2–5) every new session.
