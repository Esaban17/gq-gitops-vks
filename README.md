# gq-gitops-vks

Despliegue continuo de una app en **VKS (VCF 9.1.1)** con **GitOps (Argo CD Supervisor Service) + Helm +
External Secrets Operator**, replicando la arquitectura "Despliegue continuo de aplicaciones en VKS con
GitOps y Helm" en GQ LAB, cambiando los servicios de Azure por GitHub y AWS (ECR y Secrets Manager).

| Diagrama original | En este repo / lab |
|---|---|
| Azure Repos (código) | GitHub, carpeta `app/` |
| Azure Repos (chart + values por ambiente) | GitHub, carpeta `deploy/` (mismo repo) |
| Azure Pipelines (CI) | GitHub Actions `.github/workflows/ci.yaml` (entra a AWS por OIDC, sin llaves) |
| Azure Container Registry | Amazon ECR privado `portal-gq` (us-east-1, tags inmutables, escaneo al subir) |
| SP de Entra con AcrPull para Harbor | Usuario IAM `harbor-ecr-pull-gq-lab` de solo lectura en el endpoint ECR de Harbor |
| Harbor (proyecto privado, réplica pull programada) | Harbor regional `10.2.20.7`, proyecto `gq-apps` |
| Argo CD (operador Broadcom, namespace DevOps) | ArgoCD Service 1.3.0, instancia en `gq-apps` |
| Azure Key Vault + SP de Entra para ESO | AWS Secrets Manager + usuario IAM `eso-gq-lab` de solo lectura sobre `gq-lab/*` |
| External Secrets (chart oficial como Application) | `deploy/argocd/apps/01-external-secrets.yaml` |
| Aplicación (chart Helm, imagePullSecret robot) | `deploy/charts/portal-gq` (el robot también sale de Secrets Manager vía ESO) |
| Ingress | Service `LoadBalancer` (NSX VPC); Ingress opcional en el chart |
| VCF Automation (catálogo de clústeres) | `lab/vks/02-cluster-gq-apps-01.yaml` con kubectl |

Flujo: push en `app/` → Actions construye y publica en ECR → PR con el nuevo `image.tag` →
Harbor replica la imagen (cada 5 min) → al fusionar el PR, Argo CD sincroniza el chart en VKS →
los nodos jalan de Harbor con la cuenta robot → ESO trae los secretos de AWS Secrets Manager como Secrets nativos.

```
app/                         código de la app (FastAPI) y Dockerfile
.github/workflows/ci.yaml    CI: build, push a ECR y PR de image.tag
deploy/charts/portal-gq/     chart Helm (Deployment, Service, Ingress, ExternalSecrets)
deploy/environments/lab/     values del ambiente lab (lo toca el CI)
deploy/platform/secret-stores/  ClusterSecretStore hacia AWS Secrets Manager
deploy/argocd/apps/          Applications de Argo CD (ESO, stores, app)
lab/                         scripts de una sola vez: AWS (Secrets Manager, ECR, OIDC), Harbor, clúster VKS, registro en Argo CD
docs/GUIA.md                 paso a paso completo
```

Empieza por **[docs/GUIA.md](docs/GUIA.md)**.
