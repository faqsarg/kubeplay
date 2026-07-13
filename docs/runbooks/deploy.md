# Runbook — Bring the app up on a fresh staging cluster (GitOps)

Project strategy: **apply-then-destroy**. The cluster is destroyed at the end of each
session to avoid paying for the EKS control plane. This runbook brings the platform up
**from scratch on a freshly created cluster**, with nothing kept in memory.

Since Phase 5 the app is deployed with **GitOps (ArgoCD)**, not by pushing manifests from
a workstation. The split to keep in mind:

- **`scripts/deploy.sh`** (the *imperative* layer) bootstraps the **platform**: cluster,
  storage, secrets, ingress, Postgres, and ArgoCD itself. Run it once per fresh cluster.
- **ArgoCD** (the *declarative* layer) then owns the **apps** (backend/frontend). It reads
  the desired state from `main` and reconciles it into the cluster. Nobody `kubectl apply`s
  the apps by hand anymore.
- **CI/CD** (`.github/workflows/deploy-staging.yml`) builds+pushes images on merge to `main`
  and commits the new image tag into `kubernetes/apps/*/kustomization.yaml`. **That commit
  is the deploy** — Argo picks it up on its own.

> The fast path is a single command: `./scripts/deploy.sh`. The rest of this document is
> what that script does, step by step, and **why** — read it to understand or debug a run.

---

## 0. Prerequisites

Requires locally: `terraform`, `aws`, `kubectl`, `helm` (+ valid AWS credentials).
No `docker` is needed — images are built by CI, not here; the cluster pulls them from ECR.

```bash
# One command does everything below (idempotent; safe to re-run):
./scripts/deploy.sh

# Tear the ephemeral layer down at the end of the session (bootstrap/ is NEVER touched):
./scripts/deploy.sh teardown
```

The durable layer (S3 state backend + the AWS Secrets Manager secret + the GitHub OIDC
provider/CI role + ECR repos) lives in `bootstrap/` and **survives destroy**. `deploy.sh`
re-applies it first as a no-op; only re-run it by hand after changing `bootstrap/`.

---

## 1. Infrastructure  *(the slow/expensive step)*

```bash
terraform -chdir=bootstrap init && terraform -chdir=bootstrap apply           # durable; no-op if applied
terraform -chdir=terraform/environments/staging init                          # ephemeral cluster layer
terraform -chdir=terraform/environments/staging apply                         # creates VPC, EKS, ECR, eso_irsa role, EBS CSI addon

aws eks update-kubeconfig --region eu-west-1 --name staging-eks
kubectl get nodes                                                             # verify access
```

---

## 2. metrics-server  *(so the HPA has CPU metrics)*

EKS does **not** ship metrics-server. Without it the backend HPA stays at `<unknown>/70%`
and never scales.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl rollout status deployment/metrics-server -n kube-system
```

---

## 3. Storage — make gp3 the default StorageClass

The `aws-ebs-csi-driver` addon is installed by Terraform. Make **gp3** the default
StorageClass so Postgres' PVC binds to a real EBS volume, and demote EKS's default **gp2**
(a dead in-tree provisioner) — two defaults would leave the PVC unscheduled.

```bash
kubectl apply -f kubernetes/platform/storage/gp3-storageclass.yaml
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

---

## 4. Secret `postgres-credentials` via ESO  *(BEFORE Postgres and the backend)*

The Secret is **not** created by hand. Source of truth is AWS Secrets Manager
(`kubeplay/staging/postgres`, created in `bootstrap/`); the External Secrets Operator (ESO)
reads it via IRSA — no static keys — and materializes a native K8s Secret named
`postgres-credentials` in `default`. Two consumers read it: the Postgres chart
(`existingSecret`) and the backend Deployment (`secretKeyRef`). If it does not exist, both
pods get stuck in `CreateContainerConfigError`.

The `eso_irsa` role (least privilege: `GetSecretValue` on that one secret) is created by
`terraform apply`. ESO's ServiceAccount **must** be `external-secrets`/`external-secrets`
— that is exactly what the role's trust policy pins via the OIDC `sub` claim.

```bash
ROLE_ARN=$(terraform -chdir=terraform/environments/staging output -raw eso_irsa_role_arn)

helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace --wait \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"

# The validating webhook must have live endpoints before a (Cluster)SecretStore can be
# created, else: "no endpoints available for service external-secrets-webhook".
kubectl wait --for=condition=Available deployment --all -n external-secrets --timeout=180s

kubectl apply -f kubernetes/apps/eso/secretstore.yaml              # ClusterSecretStore (cluster-scoped)
kubectl apply -f kubernetes/apps/eso/externalsecret-staging.yaml   # ExternalSecret in default

# The ExternalSecret should report SecretSynced; the Secret must exist BEFORE Postgres boots.
kubectl get secret postgres-credentials -n default
```

- `password` → app user `kubeplay` (backend's `DATABASE_URL` and the chart's `userPasswordKey`)
- `postgres-password` → `postgres` superuser (chart-internal only)

---

## 5. ingress-nginx  *(provisions the public NLB)*

Its `LoadBalancer` Service makes AWS provision an NLB automatically. `--wait` blocks on the
controller pods (not the LB — its hostname lands on the Service a bit later).

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait \
  -f kubernetes/platform/ingress-nginx/values.yaml
```

The public host is derived from the NLB's resolved IP as `<ip>.nip.io` (nip.io maps
`<ip>.nip.io` → `<ip>`, so no real DNS is needed for staging). `deploy.sh` resolves it
automatically and substitutes it into the Ingress in step 8.

---

## 6. cert-manager + ClusterIssuer

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --set crds.enabled=true --wait

kubectl apply -f kubernetes/platform/cert-manager/clusterissuer.yaml   # config the running cert-manager reads
```

---

## 7. PostgreSQL via Helm  *(before the apps sync: the backend connects to it)*

The release **must** be named `postgres` → it generates the `postgres-postgresql` Service,
the host hardcoded in the backend's `DATABASE_URL`.

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
# chart 16.7.27 → PostgreSQL 17.6. Pin the version: the latest chart defaults to a broken
# bitnami/postgresql:latest.
helm upgrade --install postgres bitnami/postgresql \
  --version 16.7.27 -f kubernetes/apps/postgres/values.yaml
kubectl rollout status statefulset/postgres-postgresql
```

---

## 8. ArgoCD — install + register the Applications  *(the GitOps handoff)*

**The bootstrap paradox:** Argo deploys our apps declaratively from git, but Argo itself
can't self-install — so the imperative layer installs it once. From here on Argo owns
backend/frontend; `deploy.sh` only bootstraps the platform.

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace --wait

# Register the Application CRs (one-time). Each points at repoURL=this repo,
# targetRevision=main, path=kubernetes/apps/<app>, with automated sync (prune + selfHeal).
kubectl apply -f kubernetes/argocd/
```

From this point **nobody applies the apps by hand.** Argo detects `main`, runs
`kustomize build` on each app path, and syncs. Because CI has already committed a real,
existing image tag into each `kustomization.yaml`, the pods pull and roll out on their own
a couple of minutes after the Applications are registered.

### Verify the GitOps loop

```bash
kubectl get applications -n argocd                 # both should reach Synced / Healthy
kubectl get pods -n default                         # backend, frontend, postgres Running/Ready
kubectl get pod -l app=backend -n default \
  -o jsonpath='{.items[0].spec.containers[0].image}'   # should be staging-backend:<main SHA>
```

`selfHeal: true` reverts any manual drift back to git's state; `prune: true` deletes
resources once they're removed from git. The deploy is now **a commit to `main`**, nothing
more.

---

## 9. Ingress + TLS

`deploy.sh` substitutes the resolved `<HOST>` (the nip.io host from step 5) into the
Ingress, then cert-manager's ingress-shim issues the cert into the `kubeplay-tls` Secret.

```bash
sed "s|<HOST>|$HOST|g" kubernetes/apps/ingress-staging.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready certificate/kubeplay-tls --timeout=180s
```

> The app comes up on Let's Encrypt **staging** by default → the browser shows a red "not
> private" warning (the cert is real, just signed by an untrusted staging CA). Flip the
> annotation in `kubernetes/apps/ingress-staging.yaml` to `letsencrypt-prod` and re-run for a
> trusted 🔒.

---

## 10. Verify + smoke test

```bash
kubectl get pods                 # backend, frontend, postgres Running/Ready
kubectl get hpa                  # backend TARGETS should not be <unknown>
kubectl logs deploy/backend      # connects to Postgres without errors

# Public: hit the app over HTTPS at https://<HOST> (from step 5).
# Internal (no ingress): port-forward and curl the API directly.
kubectl port-forward svc/backend 8080:8080 &
curl localhost:8080/api/items
```

---

## Teardown  *(at the end of the session)*

```bash
./scripts/deploy.sh teardown
```

What it does, and why the order matters:

1. `helm uninstall ingress-nginx` **first** — deleting its LoadBalancer Service is what makes
   AWS delete the NLB. That NLB is **not** in Terraform state, so if it survives it both
   accrues cost **and** blocks VPC/subnet deletion during `terraform destroy`.
2. `helm uninstall cert-manager`.
3. `helm uninstall postgres`, then `kubectl delete pvc -l app.kubernetes.io/instance=postgres`.
   Helm retains the StatefulSet's PVC on purpose; that PVC is a real EBS volume **not** tracked
   by Terraform. Delete it before destroy or it becomes an orphan accruing cost.
4. `terraform -chdir=terraform/environments/staging destroy`.

> The Secret, the ArgoCD install, and everything else in the cluster go away with
> `terraform destroy`. `bootstrap/` (S3 state + AWS secret + OIDC/CI role + ECR) is
> intentionally left untouched, so ECR keeps the images across sessions.
```
