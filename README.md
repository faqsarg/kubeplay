# kubeplay — Production-like Cloud Platform on AWS

A modular Terraform project that provisions a Kubernetes platform on AWS (EKS),
built to mirror the day-to-day work of a Platform Engineer. The infrastructure is
the focus: networking, managed Kubernetes, IAM, and remote state are all defined
as code and reproducible from scratch.

> **Status:** Platform foundations + a full in-cluster application are working, now
> reachable from the internet over HTTPS. Remote state, networking, and the EKS cluster
> (with IRSA) are provisioned and verified. A backend API, a static frontend, and
> PostgreSQL run on the cluster, with database credentials delivered by the External
> Secrets Operator from AWS Secrets Manager (no static keys) and persistent storage on
> EBS volumes via the AWS EBS CSI driver. Public access is served by the NGINX Ingress
> Controller behind an AWS NLB, with TLS certificates issued automatically by
> cert-manager + Let's Encrypt. CI/CD and observability are the next phases.

---

## Architecture

```
                          AWS · eu-west-1
┌─────────────────────────────────────────────────────────────┐
│  VPC  10.0.0.0/16                                            │
│                                                             │
│   AZ eu-west-1a            │           AZ eu-west-1b         │
│  ┌──────────────────┐      │      ┌──────────────────┐      │
│  │ public 10.0.1/24 │      │      │ public 10.0.2/24 │      │
│  │  ┌────┐  ┌─────┐ │      │      │                  │      │
│  │  │ NAT│  │ IGW │ │      │      │                  │      │
│  └──┴─┬──┴──┴──┬──┴─┘      │      └──────────────────┘      │
│       │        │ 0.0.0.0/0 → internet                       │
│  ┌────┴─────────────┐      │      ┌──────────────────┐      │
│  │ private 10.0.3/24│      │      │ private 10.0.4/24│      │
│  │   EKS nodes  ◄───┼──────┼──────┼──►  EKS nodes    │      │
│  │ (t3.medium SPOT) │ egress via NAT only             │      │
│  └──────────────────┘      │      └──────────────────┘      │
│                                                             │
│  EKS control plane (managed) ──► OIDC provider (IRSA)       │
└─────────────────────────────────────────────────────────────┘

State backend:  S3 (versioned) + DynamoDB (state locking)
```

- **Public subnets** host the NAT Gateway and (later) load balancers. They route
  directly to the Internet Gateway.
- **Private subnets** host the EKS worker nodes. They have no inbound route from
  the internet; outbound traffic goes through a single NAT Gateway (one NAT instead
  of one-per-AZ to keep cost down).
- **Subnet tags** (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`,
  `kubernetes.io/cluster/<name>`) let EKS auto-discover where to place public and
  internal load balancers.

---

## Repository layout

| Path | Purpose |
|------|---------|
| `bootstrap/` | One-time **durable** layer that outlives cluster teardown: Terraform state backend (S3 + DynamoDB), the AWS Secrets Manager secret for Postgres, the **GitHub Actions OIDC provider + CI role**, and the **ECR repositories** (a registry must survive `destroy` so CI can push images with the cluster down). |
| `terraform/modules/networking/` | VPC, subnets, IGW, NAT, route tables, EKS subnet tags. |
| `terraform/modules/eks/` | EKS cluster, IAM roles, SPOT node group, OIDC provider for IRSA. |
| `terraform/modules/ecr/` | ECR repositories (immutable tags, scan-on-push, keep-last-10 lifecycle). |
| `terraform/modules/irsa/` | **Generic** IAM-Role-for-ServiceAccount module, reused per workload (ESO today). |
| `terraform/environments/staging/` | Wires the modules together for the staging environment. |
| `apps/backend/` | Go REST API (health + items CRUD) backed by Postgres. |
| `apps/frontend/` | Static HTML/JS page (nginx) that calls the API same-origin. |
| `kubernetes/apps/` | Deployment/Service/HPA manifests for backend, frontend, Postgres values, the ESO `ClusterSecretStore` + `ExternalSecret`, and the `Ingress` (path routing + TLS). |
| `kubernetes/platform/` | Cluster-wide platform pieces: `gp3` StorageClass, ingress-nginx Helm values, and cert-manager `ClusterIssuer`s. |
| `scripts/deploy.sh` | One-command deploy/teardown of the whole app on a fresh cluster. |
| `docs/runbooks/` | Operational procedures (the manual deploy sequence). |

---

## Modules

### `bootstrap`
Creates the backend that every other stack stores its state in:
- **S3 bucket** (`faqsarg-test-tfstate-bucket`) with versioning enabled — keeps a
  history of state files so a bad apply can be recovered.
- **DynamoDB table** (`terraform-locks`, pay-per-request) — provides state locking
  so two `apply` runs can't corrupt state concurrently.

> This module bootstraps the backend it also references. Apply it **once** at the
> start of the project; afterwards its own state lives in the bucket it created.

### `networking`
Builds a production-shaped VPC:
- VPC (`10.0.0.0/16`), Internet Gateway.
- 2 public + 2 private subnets, one pair per Availability Zone.
- A single NAT Gateway with an Elastic IP, placed in the first public subnet.
- Public and private route tables with associations.

**Outputs:** `vpc_id`, `public_subnet_ids`, `private_subnet_ids`.

### `eks`
Provisions the managed Kubernetes cluster:
- **Cluster IAM role** with `AmazonEKSClusterPolicy`.
- **Node IAM role** with worker, CNI, and ECR read-only policies.
- **EKS cluster** spanning the public + private subnets.
- **Managed node group** — `t3.medium` **SPOT** instances, scaling `min 1 /
  desired 2 / max 4`, deployed into the private subnets only.
- **IAM OIDC provider** wired to the cluster's OIDC issuer, enabling **IRSA**
  (IAM Roles for Service Accounts) so pods can assume scoped IAM roles without
  node-wide credentials.

**Outputs:** `cluster_name`, `cluster_endpoint`, `cluster_ca`, `oidc_issuer_url`,
`oidc_provider_arn`.

---

## Secrets management (External Secrets Operator)

Database credentials never live in Git. The flow is fully keyless, built on IRSA:

```
AWS Secrets Manager  ──(only ESO, via IRSA)──►  K8s Secret  ──►  Postgres + backend
  kubeplay/staging/postgres                      postgres-credentials
```

- The secret is created **once** in the durable `bootstrap/` layer, so it survives the
  per-session `destroy` of the cluster.
- The generic `irsa` module grants a least-privilege role (`GetSecretValue` on that one
  secret) to ESO's ServiceAccount — the role's trust policy pins the exact
  `namespace:serviceaccount` via the OIDC `sub` claim. No static AWS keys anywhere.
- A cluster-scoped `ClusterSecretStore` (connection config) plus a namespaced
  `ExternalSecret` (the recipe) tell ESO to materialize a native K8s `Secret`. Postgres
  and the backend just consume that Secret — neither talks to AWS.

---

## Ingress & TLS

A single public entry point fronts the whole app, with HTTPS terminated in-cluster:

```
Internet ──► AWS NLB (L4) ──► NGINX Ingress Controller (L7) ──┬─► /api/* → backend
             one per cluster    terminates TLS, routes by path └─► /*     → frontend
```

- **NGINX Ingress Controller** runs as pods behind a single **AWS NLB** (requested via a
  Service annotation, so all L7 routing happens in NGINX and the load balancer stays a
  cheap L4 pipe). One `Ingress` resource routes by path on one host: `/api/*` to the
  backend, everything else to the frontend — same-origin, so the browser makes no CORS
  requests.
- **cert-manager + Let's Encrypt** issue and renew the TLS certificate automatically. A
  single annotation on the `Ingress` makes cert-manager solve the ACME HTTP-01 challenge
  through NGINX and drop the signed certificate into a `Secret` that NGINX serves. Two
  `ClusterIssuer`s exist: **staging** (untrusted but generous rate limits, used while
  iterating) and **prod** (the real trusted certificate).
- **Domain** — the public host is a free `nip.io` name derived from the NLB's IP
  (`<nlb-ip>.nip.io`), resolved and injected at deploy time so nothing is hardcoded across
  the per-session `apply`/`destroy` cycle.

At teardown the Ingress controller is uninstalled **before** `terraform destroy` so the
NLB (an AWS resource not tracked in Terraform state) is deprovisioned and can't block VPC
deletion.

---

## Usage

**Prerequisites:** Terraform `>= 1.5`, AWS CLI configured, `kubectl`.

```bash
# 1. One-time: create the state backend
cd bootstrap
terraform init
terraform apply

# 2. Provision the staging environment (networking + EKS)
cd ../terraform/environments/staging
terraform init
terraform apply

# 3. Connect kubectl to the cluster
aws eks update-kubeconfig --region eu-west-1 --name staging-eks
kubectl get nodes
```

### Deploy the application
`scripts/deploy.sh` brings the whole app up on a fresh cluster (metrics-server → ESO
→ ingress-nginx + cert-manager → Postgres → build/push images → backend + frontend →
Ingress + TLS), then verifies it and prints the public HTTPS URL. The manual,
step-by-step version with the "why" behind each step lives in
[`docs/runbooks/deploy.md`](docs/runbooks/deploy.md).

```bash
./scripts/deploy.sh
```

### Tear down
The EKS control plane bills hourly, so destroy the environment when you're done
and recreate it (~15 min) next session. The script removes the Postgres PVC before
`destroy` (avoiding an orphan EBS volume); the durable `bootstrap/` layer is left intact:

```bash
./scripts/deploy.sh teardown
```

---

## Application — Backend API

A small Go REST API (`apps/backend/`) that serves as the workload to deploy.

**Stack:** Go (`net/http`, stdlib router) · `pgx/v5` connection pool · PostgreSQL.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | **Liveness** probe — process is up; `{"status":"ok","version":"..."}`. |
| `GET` | `/ready` | **Readiness** probe — dependencies (DB) reachable; gates Service traffic. |
| `GET` | `/api/items` | List all items. |
| `POST` | `/api/items` | Create an item — body `{"name":"..."}`. |

Configuration is read from the environment (`DATABASE_URL`); the process fails fast
on startup if it is missing or the database is unreachable. The `items` table is
created on boot via `CREATE TABLE IF NOT EXISTS`.

### Local development

```bash
cd apps/backend
cp .env.example .env          # adjust credentials; .env is gitignored

docker compose up -d          # starts PostgreSQL
set -a && . ./.env && set +a  # load env vars into the shell
go run .                      # API on :8080

curl localhost:8080/api/items
curl -X POST localhost:8080/api/items -d '{"name":"hello"}'
```

### Container image

A multi-stage build produces a static binary on a `distroless` base — a ~17 MB
image running as a non-root user:

```bash
docker build -t kubeplay-backend:dev apps/backend
```

---

## Configuration

Per-environment values live in `terraform.tfvars`. Staging defaults:

| Variable | Value |
|----------|-------|
| `environment` | `staging` |
| `cluster_name` | `staging-eks` |
| `vpc_cidr` | `10.0.0.0/16` |
| `public_subnets` | `10.0.1.0/24`, `10.0.2.0/24` |
| `private_subnets` | `10.0.3.0/24`, `10.0.4.0/24` |
| `availability_zones` | `eu-west-1a`, `eu-west-1b` |

---

## Design decisions

- **Modular Terraform** — `networking` and `eks` are independent, reusable modules;
  environments only compose them, keeping per-env code minimal.
- **Remote state with locking** — S3 + DynamoDB instead of local state, so the
  setup is team-safe and recoverable.
- **SPOT nodes** — ~70% cheaper than on-demand; acceptable for a non-production
  learning cluster.
- **Single NAT Gateway** — trades cross-AZ resilience for ~$30/mo savings.
- **IRSA over node IAM** — least-privilege at the pod level rather than granting
  broad permissions to every node.
- **ESO over committed secrets / SOPS** — the repo is public, so no ciphertext lives in
  Git at all; AWS Secrets Manager is the source of truth and ESO leverages the existing
  IRSA wiring. The same generic `irsa` module already backs the EBS CSI driver and will
  back future controllers (cluster-autoscaler, AWS Load Balancer Controller).
- **EBS CSI driver + default `gp3` StorageClass** — the in-tree `gp2` provisioner was
  removed in EKS 1.23+, so PersistentVolumeClaims stay `Pending` without it. The managed
  `aws-ebs-csi-driver` addon (wired via IRSA) provisions real EBS volumes, and `gp3` is
  set as the default class so Postgres data survives pod restarts.
- **NGINX Ingress + NLB (not ALB)** — the AWS load balancer is a plain L4 NLB; all
  host/path routing and TLS termination happen inside NGINX. This keeps a single load
  balancer for every service (instead of one per `Service type=LoadBalancer`) and one
  place to terminate TLS.
- **cert-manager staging then prod** — deploys start on Let's Encrypt **staging** to avoid
  burning the strict production rate limits during the frequent `apply`/`destroy` cycle,
  and switch to **prod** once issuance is confirmed. Domain is free `nip.io` (no Route53
  cost) for an ephemeral learning environment.
- **Config vs. secrets split** — non-sensitive DB settings live in a `ConfigMap`
  (versioned in Git), the password comes from the ESO-synced `Secret`, and the Deployment
  assembles `DATABASE_URL` from both via `$(VAR)` expansion.
- **Pinned `bitnamilegacy` Postgres image** — Bitnami moved its free images to a frozen
  `bitnamilegacy/` namespace (Aug 2025); the chart is pinned to a known-good PostgreSQL
  17.6 image there. A documented stopgap until a maintained image is adopted.

---

## Cost

Running 4h/day on weekdays and destroying afterwards: **~$15–20/mo**. The EKS
control plane (`$0.10/h`) is the only unavoidable cost while the cluster is up and
is **not** covered by the AWS Free Tier.
