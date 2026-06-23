# kubeplay — Production-like Cloud Platform on AWS

A modular Terraform project that provisions a Kubernetes platform on AWS (EKS),
built to mirror the day-to-day work of a Platform Engineer. The infrastructure is
the focus: networking, managed Kubernetes, IAM, and remote state are all defined
as code and reproducible from scratch.

> **Status:** Foundations complete — remote state, networking, and the EKS cluster
> (with IRSA) are provisioned and verified. The backend API exists and runs locally
> against Postgres; Kubernetes manifests, ingress, CI/CD, and observability are planned.

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
| `bootstrap/` | One-time setup of the Terraform **remote state backend** (S3 + DynamoDB). |
| `terraform/modules/networking/` | VPC, subnets, IGW, NAT, route tables, EKS subnet tags. |
| `terraform/modules/eks/` | EKS cluster, IAM roles, SPOT node group, OIDC provider for IRSA. |
| `terraform/environments/staging/` | Wires the modules together for the staging environment. |
| `apps/backend/` | Go REST API (health + items CRUD) backed by Postgres. |
| `kubernetes/`, `.github/`, `docs/` | Reserved for upcoming phases (manifests, CI/CD, ADRs). |

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
aws eks update-kubeconfig --region eu-west-1 --name kubeplay-staging
kubectl get nodes
```

### Tear down
The EKS control plane bills hourly, so destroy the environment when you're done
and recreate it (~15 min) next session:

```bash
cd terraform/environments/staging
terraform destroy
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
| `cluster_name` | `kubeplay-staging` |
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

---

## Cost

Running 4h/day on weekdays and destroying afterwards: **~$15–20/mo**. The EKS
control plane (`$0.10/h`) is the only unavoidable cost while the cluster is up and
is **not** covered by the AWS Free Tier.
