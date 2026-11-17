# Guía: GitOps en VKS con Argo CD, Helm y External Secrets (GQ LAB, VCF 9.1.1)

Orden recomendado. Cada paso dice **dónde** se corre. "Mac" = tu Mac con `vcf`, `kubectl`, `az`, `jq`
(o la VM pais-deps 10.2.15.51, que ya tiene `kubectl` y el contexto `sp-gq`).

## 0. Prerrequisitos
- ArgoCD Service 1.3.0 instalado en `supervisor-gq` y una instancia `ArgoCD` corriendo en el namespace
  `argocd-gq` (ver `argocd-service/GUIA-ARGOCD-SERVICE.md`). Comprueba: `kubectl -n argocd-gq get pods`.
- Harbor regional Healthy (`https://10.2.20.7`, FQDN `depot.kube-system.svc`).
- Salida a Internet (HTTPS 443), igual que en el recuadro rojo del diagrama:
  - Harbor → `ghcr.io`, `pkg-containers.githubusercontent.com`
  - Nodos VKS → `ghcr.io` (imágenes de ESO), `<vault>.vault.azure.net`, `login.microsoftonline.com`
  - Argo CD (repo-server) → `github.com`, `charts.external-secrets.io`, `objects.githubusercontent.com`

## 1. GitHub (repo, Actions y token para Harbor)
1. Repo `Esaban17/gq-gitops-vks` (público, así Argo CD lo lee sin credenciales).
2. Settings > Actions > General > Workflow permissions: **Read and write permissions** y marcar
   **Allow GitHub Actions to create and approve pull requests** (el CI abre el PR del paso 3).
3. Un PAT *classic* solo con `read:packages` (Settings > Developer settings > Personal access tokens).
   Es el equivalente del SP de Harbor con AcrPull. Lo pide el script de Harbor; no se guarda en Git.

## 2. Azure Key Vault (Mac)
1. Crea la cuenta gratis en https://azure.microsoft.com/free (pide tarjeta para verificar identidad).
   Key Vault Standard cobra ~USD 0.03 por cada 10,000 operaciones; con `refreshInterval: 1m` y 2
   ExternalSecrets son unas 90,000 lecturas al mes, menos de USD 0.30 (y entra en el crédito inicial).
   Para gastar menos, sube `externalSecrets.refreshInterval` a `1h` cuando termines la demo.
2. `brew install azure-cli` y luego:
   ```
   bash lab/azure/01-crear-keyvault.sh
   ```
   Crea `rg-gq-lab-gitops` (East US 2), el vault `kv-gq-lab-xxxxx` en modo RBAC, el SP `sp-eso-gq-lab`
   con **Key Vault Secrets User** y 4 secretos de demo. Las credenciales del SP quedan en
   `lab/azure/.eso-sp.env` (600, ignorado por Git).
3. Pon el `vaultUrl` y el `tenantId` que imprime en
   `deploy/platform/secret-stores/clustersecretstore-azure-kv.yaml` y haz commit (o pásamelos y abro el PR).

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
Resultado: imagen `ghcr.io/esaban17/portal-gq:sha-xxxxxxx` y un PR "lab: desplegar portal-gq sha-xxxxxxx".
**No lo fusiones todavía.**

## 5. Harbor: proyecto privado, réplica pull y cuenta robot (Mac)
Con `az` logueado (para que el robot quede en Key Vault):
```
bash lab/harbor/configurar-harbor.sh
```
Pide el password de admin de Harbor (secret `harbor-core` del namespace `svc-harbor-s7los`) y el PAT.
Crea el proyecto `gq-apps` (privado), el endpoint `ghcr` (adaptador *Github GHCR*), la regla
`ghcr-portal-gq` (pull, filtro `esaban17/portal-gq` + tags `sha-*`, cada 5 min, destino `gq-apps`),
la cuenta robot `robot$gq-apps+portal-gq-pull` de solo pull, y guarda usuario/secret del robot en
Key Vault (`harbor-robot-portal-gq-user/-password`). Lanza una primera ejecución.
Verifica en Harbor > Projects > gq-apps que aparece `portal-gq` con el tag del paso 4.

## 6. Secreto cero de ESO (Mac)
```
KUBECONFIG=~/.kube/gq-apps-01.kubeconfig bash lab/azure/02-bootstrap-eso-sp.sh
```
Crea `external-secrets/azure-kv-sp` (client id/secret del SP). Es lo único que no viene de Git ni de Key Vault,
igual que en el diagrama.

## 7. Argo CD: registrar el clúster y crear las Applications (Mac)
```
bash lab/argocd/registrar-cluster-vks.sh
kubectl --context sp-gq -n argocd-gq apply -f deploy/argocd/apps/
```
Orden por sync-wave: `external-secrets` (chart oficial 2.15.0) → `secret-stores` (ClusterSecretStore
`azure-kv`) → `portal-gq-lab` (chart de la app). Las dos últimas reintentan solas mientras ESO arranca.
Ahora sí **fusiona el PR del paso 4**: Argo CD detecta el cambio en Git y hace el rolling update.

Comprobaciones (con `KUBECONFIG=~/.kube/gq-apps-01.kubeconfig`):
```
kubectl get clustersecretstore azure-kv                  # READY True
kubectl -n portal-gq get externalsecret                  # SecretSynced
kubectl -n portal-gq get secret portal-gq-config harbor-pull
kubectl -n portal-gq get pods,svc                        # EXTERNAL-IP del Service portal-gq
```
Abre `http://<EXTERNAL-IP>`.

## 8. Demo (el flujo completo del diagrama)
**Nueva versión:** cambia algo en `app/main.py` y haz push a `main`.
Actions publica `sha-nuevo` en GHCR (1-2) y abre el PR de `image.tag` (3) → Harbor replica en ≤5 min (4) →
fusionas el PR → Argo CD sincroniza (5-6) → los pods nuevos jalan de Harbor con el robot (7).
La tarjeta "Versión desplegada" muestra el tag nuevo.

**Rotación de secretos (8):**
```
az keyvault secret set --vault-name <vault> -n portal-gq-mensaje --value "Hola desde Azure Key Vault (v2)"
```
En 1-2 minutos el "Mensaje" cambia **sin reiniciar** (archivo montado). Las variables de entorno
(`DB_PASSWORD`, `API_KEY`) solo cambian al reiniciar:
`kubectl -n portal-gq rollout restart deploy/portal-gq`.

**Rollback:** revierte el commit del PR de `image.tag` en GitHub; Argo CD vuelve a la versión anterior.

## Qué se omitió o cambió y por qué
- **Azure Repos / Pipelines / ACR**: de pago o atados a Azure DevOps; GitHub + Actions + GHCR son gratis y
  equivalentes. Código y chart viven en el mismo repo (se pueden separar; el CI necesitaría un token
  para abrir el PR en el otro repo).
- **SP de Entra para Harbor (AcrPull)**: no aplica a GHCR; lo reemplaza un PAT de GitHub `read:packages`.
- **VCF Automation como catálogo de clústeres**: el clúster se crea con kubectl; se puede publicar luego
  como ítem de catálogo en la org `gq-org`.
- **Ingress**: el Service es `LoadBalancer` (NSX VPC da la IP). Para Ingress real, instala Contour como
  paquete de VKS y pon `ingress.enabled: true` y `ingress.className: contour` en el values del ambiente.

## Problemas comunes
| Síntoma | Causa probable |
|---|---|
| `ClusterSecretStore azure-kv` en `InvalidProviderConfig` | `vaultUrl`/`tenantId` sin reemplazar, o falta el Secret `azure-kv-sp` |
| ExternalSecret `403 Forbidden` | RBAC del SP aún propagando (espera 5 min) o rol mal asignado |
| `ImagePullBackOff` con `x509` | nodos sin la CA de Harbor: revisar paso 3.2 y la variable `trust` del clúster |
| `ImagePullBackOff` con `not found` | la réplica no ha corrido aún; ejecútala a mano en Harbor > Replications |
| `ImagePullBackOff` con `unauthorized` | el Secret `harbor-pull` no existe o el robot cambió en Key Vault |
| Argo CD `cluster gq-apps-01 not found` | no se corrió `registrar-cluster-vks.sh` o el Secret quedó en otro namespace |
| Pods de ESO sin imagen | los nodos VKS no salen a `ghcr.io`: abrir salida o usar un proxy cache en Harbor |
| La réplica de Harbor no lista repos | GHCR no expone catálogo con el adaptador genérico: usar el tipo *Github GHCR* |
