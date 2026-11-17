# Guía: GitOps en VKS con Argo CD, Helm y External Secrets (GQ LAB, VCF 9.1.1)

Orden recomendado. Cada paso dice **dónde** se corre. "Mac" = tu Mac con `vcf`, `kubectl`, `aws`, `jq`
(o la VM pais-deps 10.2.15.51, que ya tiene `kubectl` y el contexto `sp-gq`). `aws` es la AWS CLI v2.

## 0. Prerrequisitos
- ArgoCD Service 1.3.0 instalado en `supervisor-gq` y una instancia `ArgoCD` corriendo en el namespace
  `gq-apps`, el mismo vSphere Namespace del clúster VKS (`lab/argocd/argocd-instancia.yaml`). Comprueba: `kubectl -n gq-apps get argocd,pods`.
- Harbor regional Healthy (`https://10.2.20.7`, FQDN `depot.kube-system.svc`).
- Salida a Internet (HTTPS 443), igual que en el recuadro rojo del diagrama:
  - Harbor → `api.ecr.us-east-1.amazonaws.com`, `<cuenta>.dkr.ecr.us-east-1.amazonaws.com`,
    `prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com` (capas de ECR)
  - Nodos VKS → `ghcr.io` (imágenes de ESO), `secretsmanager.us-east-1.amazonaws.com`, `sts.amazonaws.com`
  - Argo CD (repo-server) → `github.com`, `charts.external-secrets.io`, `objects.githubusercontent.com`

## 1. GitHub (repo y Actions)
1. Repo `Esaban17/gq-gitops-vks` (público, así Argo CD lo lee sin credenciales).
2. Settings > Actions > General > Workflow permissions: **Read and write permissions** y marcar
   **Allow GitHub Actions to create and approve pull requests** (el CI abre el PR del paso 3).
3. Variable de repositorio `AWS_ROLE_ARN` (la crea `lab/aws/03-crear-ecr.sh` si tienes `gh`; si no, el script
   te dice el valor para ponerlo en Settings > Secrets and variables > Actions > Variables).

## 2. AWS Secrets Manager (Mac)
Sustituye al Azure Key Vault del diagrama; el usuario IAM `eso-gq-lab` hace el papel del service principal.
1. `brew install awscli` y credenciales de administrador de tu cuenta AWS (`aws configure` o `aws sso login`).
   Comprueba con `aws sts get-caller-identity`.
2. Corre:
   ```
   bash lab/aws/01-crear-secretos.sh
   ```
   Crea en `us-east-1` el secreto `gq-lab/portal-gq` (JSON con `db_user`, `db_password`, `api_key`, `mensaje`)
   y el usuario IAM `eso-gq-lab` con política de solo lectura (`GetSecretValue`, `DescribeSecret`) sobre
   `gq-lab/*`, más un access key. El access key queda en `lab/aws/.eso-aws.env` (600, ignorado por Git).
   Otra región: `AWS_REGION=us-east-2 bash lab/aws/01-crear-secretos.sh` y cambia `region` en
   `deploy/platform/secret-stores/clustersecretstore-aws-sm.yaml`.
3. Costo: Secrets Manager cobra USD 0.40 por secreto al mes (los secretos nuevos tienen 30 días de prueba) y
   USD 0.05 por cada 10,000 llamadas. Con 2 secretos y `refreshInterval: 1m` son ~USD 1.30 al mes.
   Sube `externalSecrets.refreshInterval` a `1h` al terminar la demo.

## 2b. Amazon ECR + OIDC para el CI (Mac)
Sustituye al ACR del diagrama.
```
bash lab/aws/03-crear-ecr.sh
```
Crea el repositorio ECR privado `portal-gq` (tags inmutables, escaneo al subir, conserva 20 imágenes), el
proveedor OIDC de GitHub y el rol `gha-ecr-push-gq-lab` (solo push a ese repo y solo desde `main` de este repo:
GitHub no guarda llaves de AWS), y el usuario IAM `harbor-ecr-pull-gq-lab` de solo lectura para Harbor
(equivale al SP de Harbor con AcrPull). Su access key queda en `lab/aws/.harbor-ecr.env` (600, ignorado por Git).
Costo: ECR cobra USD 0.10 por GB-mes; una imagen de esta app pesa ~60 MB.

## 3. Clúster VKS `gq-apps-01` (Mac, contexto `sp-gq`)
1. vCenter > Supervisor Management > Namespaces > **New Namespace** `gq-apps` en `supervisor-gq`:
   storage policy, VM classes (al menos `best-effort-medium`) y permiso Owner para tu usuario/grupo.
2. CA de Harbor para los nodos (antes de crear el clúster):
   ```
   vcf context use sp-gq
   bash lab/vks/01-preparar-ca-harbor.sh
   ```
3. Revisa los valores `CONFIRMAR/REEMPLAZAR` de `lab/vks/02-cluster-gq-apps-01.yaml` con los comandos
   del encabezado y aplica:
   ```
   kubectl apply -f lab/vks/02-cluster-gq-apps-01.yaml
   kubectl -n gq-apps get cluster gq-apps-01 -w      # hasta que esté Provisioned (~10-15 min)
   bash lab/vks/03-kubeconfig.sh                     # deja ~/.kube/gq-apps-01.kubeconfig
   ```

## 4. Primera imagen (GitHub)
Con el repo ya en `main`, corre el workflow **ci-portal-gq** (Actions > Run workflow) o haz un push en `app/`.
Resultado: imagen `<cuenta>.dkr.ecr.us-east-1.amazonaws.com/portal-gq:sha-xxxxxxx` y un PR "lab: desplegar portal-gq sha-xxxxxxx".
**No lo fusiones todavía.**

## 5. Harbor: proyecto privado, réplica pull y cuenta robot (Mac)
Con la AWS CLI logueada (para que el robot quede en Secrets Manager):
```
bash lab/harbor/configurar-harbor.sh
```
Pide el password de admin de Harbor (secret `harbor-core` del namespace `svc-harbor-s7los`) y usa la llave de
`lab/aws/.harbor-ecr.env`. Crea el proyecto `gq-apps` (privado), el endpoint `ecr-us-east-1` (adaptador
*AWS ECR*), la regla `ecr-portal-gq` (pull, filtro `portal-gq` + tags `sha-*`, cada 5 min, destino `gq-apps`
aplanando niveles), desactiva la regla vieja `ghcr-portal-gq` si existe,
la cuenta robot `robot$gq-apps+portal-gq-pull` de solo pull, y guarda usuario/secret del robot en
Secrets Manager (`gq-lab/harbor-robot-portal-gq`, JSON `username`/`password`). Lanza una primera ejecución.
Verifica en Harbor > Projects > gq-apps que aparece `portal-gq` con el tag del paso 4.

## 6. Secreto cero de ESO (Mac)
```
KUBECONFIG=~/.kube/gq-apps-01.kubeconfig bash lab/aws/02-bootstrap-eso-creds.sh
```
Crea `external-secrets/aws-sm-creds` (access key del usuario IAM). Es lo único que no viene de Git ni de
Secrets Manager, igual que el secreto del SP en el diagrama.

## 7. Argo CD: registrar el clúster y crear las Applications (Mac)
```
bash lab/argocd/registrar-cluster-vks.sh
kubectl --context sp-gq -n gq-apps apply -f deploy/argocd/apps/
```
Orden por sync-wave: `external-secrets` (chart oficial 2.15.0) → `secret-stores` (ClusterSecretStore
`aws-sm`) → `portal-gq-lab` (chart de la app). Las dos últimas reintentan solas mientras ESO arranca.
Ahora sí **fusiona el PR del paso 4**: Argo CD detecta el cambio en Git y hace el rolling update.

Comprobaciones (con `KUBECONFIG=~/.kube/gq-apps-01.kubeconfig`):
```
kubectl get clustersecretstore aws-sm                    # READY True
kubectl -n portal-gq get externalsecret                  # SecretSynced
kubectl -n portal-gq get secret portal-gq-config harbor-pull
kubectl -n portal-gq get pods,svc                        # EXTERNAL-IP del Service portal-gq
```
Abre `http://<EXTERNAL-IP>`.

## 8. Demo (el flujo completo del diagrama)
**Nueva versión:** cambia algo en `app/main.py` y haz push a `main`.
Actions publica `sha-nuevo` en ECR (1-2) y abre el PR de `image.tag` (3) → Harbor replica en ≤5 min (4) →
fusionas el PR → Argo CD sincroniza (5-6) → los pods nuevos jalan de Harbor con el robot (7).
La tarjeta "Versión desplegada" muestra el tag nuevo.

**Rotación de secretos (8):**
```
SECRET=$(aws secretsmanager get-secret-value --secret-id gq-lab/portal-gq --query SecretString --output text)
aws secretsmanager put-secret-value --secret-id gq-lab/portal-gq \
  --secret-string "$(echo "$SECRET" | jq -c '.mensaje = "Hola desde AWS Secrets Manager (v2)"')"
```
En 1-2 minutos el "Mensaje" cambia **sin reiniciar** (archivo montado). Las variables de entorno
(`DB_PASSWORD`, `API_KEY`) solo cambian al reiniciar:
`kubectl -n portal-gq rollout restart deploy/portal-gq`.

**Rollback:** revierte el commit del PR de `image.tag` en GitHub; Argo CD vuelve a la versión anterior.

## Qué se omitió o cambió y por qué
- **Azure Repos / Pipelines / ACR**: sin cuenta de Azure; GitHub + Actions como repos y CI, y Amazon ECR como
  registro de la nube (igual que ACR: privado, Harbor replica en modo pull con una identidad de solo lectura). Código y chart viven en el mismo repo (se pueden separar; el CI necesitaría un token
  para abrir el PR en el otro repo).
- **Azure Key Vault + SP de Entra para ESO**: sin cuenta de Azure (la prueba gratis no deja registrarse con
  la cuenta corporativa); AWS Secrets Manager + usuario IAM de solo lectura es el mismo patrón: ESO sale por
  HTTPS 443, autentica con una credencial guardada como secreto cero y crea Secrets nativos.
  Alternativa sin costo: `service: ParameterStore` (parámetros SecureString estándar) en el mismo ClusterSecretStore.
- **SP de Entra para Harbor (AcrPull)**: lo reemplaza el usuario IAM `harbor-ecr-pull-gq-lab` (solo lectura).
- **Credenciales del pipeline**: el CI entra a AWS por OIDC (rol federado), sin llaves guardadas en GitHub.
- **VCF Automation como catálogo de clústeres**: el clúster se crea con kubectl; se puede publicar luego
  como ítem de catálogo en la org `gq-org`.
- **Ingress**: el Service es `LoadBalancer` (NSX VPC da la IP). Para Ingress real, instala Contour como
  paquete de VKS y pon `ingress.enabled: true` y `ingress.className: contour` en el values del ambiente.

## Problemas comunes
| Síntoma | Causa probable |
|---|---|
| `ClusterSecretStore aws-sm` no queda Ready | falta el Secret `aws-sm-creds` o la región no coincide |
| ExternalSecret `AccessDeniedException` | la política IAM no cubre el ARN (región/cuenta/prefijo `gq-lab/`) |
| ExternalSecret `ResourceNotFoundException` | el secreto no existe en esa región o el nombre/`property` no coincide |
| `ImagePullBackOff` con `x509` | nodos sin la CA de Harbor: revisar paso 3.2 y la variable `trust` del clúster |
| `ImagePullBackOff` con `not found` | la réplica no ha corrido aún; ejecútala a mano en Harbor > Replications |
| `ImagePullBackOff` con `unauthorized` | el Secret `harbor-pull` no existe o el robot cambió en Secrets Manager |
| Argo CD `cluster gq-apps-01 not found` | no se corrió `registrar-cluster-vks.sh` o el Secret quedó en otro namespace |
| Pods de ESO sin imagen | los nodos VKS no salen a `ghcr.io`: abrir salida o usar un proxy cache en Harbor |
| La réplica de Harbor falla con `AccessDenied` | política del usuario `harbor-ecr-pull-gq-lab` o región del endpoint |
| La réplica falla descargando capas | Harbor sin salida al bucket S3 de capas de ECR (ver prerrequisitos) |
| CI: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | falta `AWS_ROLE_ARN`, o el run no viene de `main` de este repo |
