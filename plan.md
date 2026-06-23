  Plan: Production-like Cloud Platform on AWS

  Resumen ejecutivo

  Un proyecto de plataforma cloud que replica el trabajo real de un Platform Engineer en una startup. La infraestructura importa más que la aplicación. Al terminar, tenés
  8-10 bullets concretos para el CV que suenan a trabajo real.

  ---
  Stack definitivo

  ┌─────────────────┬──────────────────────────────────────────┬─────────────────────────────────────────────────┐
  │      Capa       │                Tecnología                │                     Por qué                     │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Cloud           │ AWS                                      │ Estándar de la industria                        │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ IaC             │ Terraform (modular)                      │ Lo más pedido en Europa                         │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Orquestación    │ EKS (Kubernetes)                         │ Managed, realista                               │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Package manager │ Helm                                     │ Standard de facto                               │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Ingress         │ NGINX Ingress Controller                 │ Simple, documentado                             │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ TLS             │ cert-manager + Let's Encrypt             │ Gratis, real                                    │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ CI/CD           │ GitHub Actions                           │ Gratis para repos públicos                      │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Registry        │ ECR                                      │ Integra nativo con EKS                          │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Monitoreo       │ kube-prometheus-stack                    │ Prometheus + Grafana + Alertmanager en un chart │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Logs            │ Loki + Promtail                          │ Liviano, integra con Grafana                    │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ Secrets         │ SOPS + age (o External Secrets Operator) │ Sin costo extra                                 │
  ├─────────────────┼──────────────────────────────────────────┼─────────────────────────────────────────────────┤
  │ App             │ Go API + PostgreSQL (Helm)               │ Simple, limpio                                  │
  └─────────────────┴──────────────────────────────────────────┴─────────────────────────────────────────────────┘

  ---
  Estructura del repositorio

  cloud-platform/
  ├── terraform/
  │   ├── modules/
  │   │   ├── networking/       # VPC, subnets, NAT, SG
  │   │   ├── eks/              # cluster, node groups, IAM
  │   │   ├── ecr/              # repositorios Docker
  │   │   └── dns/              # Route53 (opcional)
  │   ├── environments/
  │   │   ├── staging/
  │   │   │   ├── main.tf
  │   │   │   ├── variables.tf
  │   │   │   └── terraform.tfvars
  │   │   └── production/
  │   │       ├── main.tf
  │   │       ├── variables.tf
  │   │       └── terraform.tfvars
  │   └── backend/              # S3 + DynamoDB state
  ├── kubernetes/
  │   ├── apps/
  │   │   ├── backend/          # Deployment, Service, HPA, ConfigMap
  │   │   ├── frontend/
  │   │   └── postgres/
  │   └── platform/
  │       ├── ingress-nginx/
  │       ├── cert-manager/
  │       ├── monitoring/       # Prometheus, Grafana, Loki
  │       └── namespaces/
  ├── apps/
  │   ├── backend/              # Go: health + CRUD básico
  │   └── frontend/             # HTML/JS con nginx
  ├── .github/
  │   └── workflows/
  │       ├── ci.yml            # tests + build + push ECR
  │       ├── deploy-staging.yml
  │       └── deploy-production.yml   # con manual approval gate
  ├── docs/
  │   ├── architecture.md
  │   ├── runbooks/
  │   └── decisions/            # ADRs
  └── README.md

  ---
  Fases del proyecto

  Fase 0 — Fundación (Día 1-2)

  Objetivo: entorno listo, sin perder tiempo después.

  - Crear cuenta AWS Free Tier (si no existe)
  - Crear IAM user con permisos mínimos (no usar root)
  - Activar billing alerts: $10, $50, $100
  - Instalar herramientas locales: terraform, kubectl, helm, aws-cli, docker, sops
  - Crear repo GitHub: cloud-platform (público para CV)
  - Configurar remote state: bucket S3 + tabla DynamoDB para lock
  - Configurar .gitignore, .editorconfig, pre-commit hooks

  Entregable: repo vacío con estructura de carpetas, remote state funcionando.

  ---
  Fase 1 — Networking (Día 3-5)

  Objetivo: VPC production-ready como primer módulo Terraform.

  VPC (10.0.0.0/16)
    ├── public subnets  (10.0.1.0/24, 10.0.2.0/24)  → ALB, NAT
    └── private subnets (10.0.3.0/24, 10.0.4.0/24) → EKS nodes

  - Módulo networking: VPC, subnets, IGW, route tables
  - 1 sola NAT Gateway (para ahorrar ~$30/mes)
  - Security Groups base
  - IAM roles para EKS (cluster + nodes)
  - Tags correctos (requeridos por EKS: kubernetes.io/cluster/<name>)

  Aprendizaje clave: entender public vs private subnets, por qué los nodes van en private, qué hace el NAT.

  ---
  Fase 2 — EKS Cluster (Día 6-10)

  Objetivo: cluster Kubernetes funcionando con Terraform.

  - Módulo eks: cluster + node group
  - Spot instances (t3.medium spot: ~$0.013/hora vs $0.042 on-demand)
  - Node group con min=1, desired=2, max=4
  - IRSA (IAM Roles for Service Accounts) configurado
  - kubeconfig generado automáticamente
  - Verificar con kubectl get nodes

  Aprendizaje clave: IRSA (cómo los pods asumen roles IAM), node groups, por qué spot para aprendizaje.

  ---
  Fase 3 — Aplicación (Día 11-15)
  
  Objetivo: algo que deployar. Simple pero funcional.

  Backend Go — 3 endpoints:
  GET  /health        → { status: "ok", version: "1.0.0" }
  GET  /api/items     → lista desde Postgres
  POST /api/items     → crear item

  Frontend — HTML/JS estático servido por nginx:
  - Llama al backend
  - Muestra lista de items
  - Formulario para crear

  Kubernetes manifests:
  - Deployment + Service para backend y frontend
  - HorizontalPodAutoscaler (min:2, max:5, CPU 70%)
  - ConfigMap para variables no sensibles
  - Secret para credenciales DB (encriptadas con SOPS)
  - PostgreSQL via Helm chart (bitnami/postgresql)
  - PersistentVolumeClaim para Postgres

  ---
  Fase 4 — Ingress y TLS (Día 16-18)

  Objetivo: HTTPS funcionando desde internet.

  - Instalar ingress-nginx via Helm
  - Instalar cert-manager via Helm
  - ClusterIssuer con Let's Encrypt
  - Ingress resource con anotaciones TLS
  - Dos opciones de dominio:
    - Con costo: Route53 + dominio (~$12/año) → más profesional
    - Sin costo: usar dominio de Freenom o nip.io con la IP del ALB

  Aprendizaje clave: cómo funciona el ingress controller, qué es cert-manager, challenge HTTP-01.

  ---
  Fase 5 — CI/CD (Día 19-24)

  Objetivo: zero-touch deployments.

  Workflow ci.yml (en cada PR):
  lint → test → docker build → push to ECR (tag: branch-sha)
  
  Workflow deploy-staging.yml (merge a main):
  build → push ECR → kubectl rollout (staging namespace)

  Workflow deploy-production.yml (tag v* o manual):
  approval gate → kubectl rollout (production namespace) → smoke test
  
  - GitHub OIDC → AWS (sin AWS keys en secrets, más seguro)
  - ECR lifecycle policy (retener últimas 10 imágenes)
  - Rollback automático si health check falla
  - Environment variables por ambiente (GitHub Environments)

  Aprendizaje clave: OIDC vs access keys, rollout strategies, environment promotion.

  ---
  Fase 6 — Observability (Día 25-32)

  Objetivo: monitoring real, no sólo instalación.

  Stack (todo via Helm):
  kube-prometheus-stack → Prometheus + Grafana + Alertmanager
  loki-stack            → Loki + Promtail

  Dashboards a construir en Grafana:
  1. Cluster Overview: CPU/memoria por nodo, pod count, restarts
  2. Application: HTTP requests/seg, latencia p50/p95/p99, error rate
  3. Kubernetes Workloads: por deployment, réplicas up vs desired
  4. Logs Explorer: búsqueda en Loki por pod/namespace

  Alertas:
  - Pod restart > 3 en 5 min → warning
  - CPU node > 80% 10 min → warning
  - Error rate > 5% → critical
  - Pod no scheduled → critical
  
  Aprendizaje clave: PromQL, label selectors, la diferencia entre métricas y logs.

  ---
  Fase 7 — Seguridad y hardening (Día 33-37)

  Objetivo: no dejar huecos evidentes.

  - IAM least privilege: cada componente con el mínimo necesario
  - SOPS + age: secrets encriptados en Git (nunca plaintext)
  - Network Policies: pods no se hablan entre namespaces por default
  - Pod Security Standards: restricted en namespace de app
  - Trivy: scan de imágenes en CI (gratis, open source)
  - Revisar security groups: nada abierto al mundo excepto 80/443

  ---
  Fase 8 — Documentación y polish (Día 38-42)

  Objetivo: que un recruiter/senior lo entienda en 5 minutos.

  README.md (el más importante):
  ## Architecture
  [diagrama con draw.io o Mermaid]

  ## Stack
  [tabla con tecnologías y por qué]

  ## How to deploy
  [paso a paso, sin ambigüedad]
  
  ## CI/CD flow
  [diagrama del pipeline]

  ## Observability
  [screenshots de los dashboards]
  
  ## Security decisions
  [qué se hizo y por qué]

  ## Cost breakdown
  [cuánto cuesta correr esto]
  
  - docs/decisions/ — mínimo 3 ADRs (Architecture Decision Records)
  - docs/runbooks/ — runbook de troubleshooting
  - Git history limpio: commits convencionales, PRs por fase

  ---
  Estimación de costos

  Estrategia de ahorro: destroy cuando no usás

  Con Terraform podés destruir y recrear en ~15 minutos.

  ┌───────────────────┬──────────────────────┬────────────────────────────────────┐
  │    Componente     │      Costo/hora      │ Costo si corrés 4h/día, 5 días/sem │
  ├───────────────────┼──────────────────────┼────────────────────────────────────┤
  │ EKS control plane │ $0.10                │ ~$8/mes                            │
  ├───────────────────┼──────────────────────┼────────────────────────────────────┤
  │ 2x t3.medium spot │ $0.026               │ ~$2/mes                            │
  ├───────────────────┼──────────────────────┼────────────────────────────────────┤
  │ NAT Gateway       │ $0.045 + data        │ ~$5/mes                            │
  ├───────────────────┼──────────────────────┼────────────────────────────────────┤
  │ ALB               │ $0.008 + LCU         │ ~$2/mes                            │
  ├───────────────────┼──────────────────────┼────────────────────────────────────┤
  │ ECR               │ ~gratis (500MB free) │ $0                                 │
  ├───────────────────┼──────────────────────┼────────────────────────────────────┤
  │ S3 (state)        │ ~gratis              │ $0                                 │
  ├───────────────────┼──────────────────────┼────────────────────────────────────┤
  │ Total estimado    │                      │ ~$15-20/mes                        │
  └───────────────────┴──────────────────────┴────────────────────────────────────┘

  Si corrés todo el mes 24/7: ~$120/mes. Si hacés terraform destroy al terminar de estudiar: < $20/mes.

  ▎ Free tier: el control plane de EKS no entra en free tier. Es el único costo inevitable cuando el cluster está up.

  ---

  1. Fases 0-2: infra base (sin esto nada funciona)
  2. Fase 5: CI/CD (lo más diferenciador en CVs)
  3. Fase 6: Observability (lo más mencionado en Europa)
  4. Fases 3-4: app e ingress (necesario para tener algo visible)
  5. Fases 7-8: security y docs (lo que distingue amateur de profesional)

  ---
  Resultado final en el CV

  • Diseñé y desplegué un cluster EKS en AWS usando Terraform modular
    con módulos separados para networking, EKS y monitoring.

  • Implementé pipelines CI/CD con GitHub Actions usando OIDC para
    autenticación sin credenciales, con promotion staging → production.

  • Construí stack de observability con Prometheus, Grafana y Loki,
    incluyendo alertas y dashboards custom de latencia y error rate.

  • Gestioné secrets con SOPS+age y apliqué Network Policies y
    Pod Security Standards en el cluster.

  • Implementé HTTPS con cert-manager y Let's Encrypt sobre
    NGINX Ingress Controller con ALB en AWS.
