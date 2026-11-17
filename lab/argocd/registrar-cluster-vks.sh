#!/usr/bin/env bash
# Registra el clúster VKS como destino de la instancia de Argo CD del Supervisor (namespace argocd-gq),
# igual que `argocd cluster add` pero sin el CLI de argocd:
#   1) en el VKS: ServiceAccount argocd-manager + token
#   2) en el Supervisor: Secret de tipo cluster en el namespace de Argo CD
# Uso:  bash lab/argocd/registrar-cluster-vks.sh     (necesita ~/.kube/gq-apps-01.kubeconfig y el contexto sp-gq)
set -euo pipefail
CLUSTER="${CLUSTER:-gq-apps-01}"
VKS_KUBECONFIG="${VKS_KUBECONFIG:-$HOME/.kube/$CLUSTER.kubeconfig}"
SUP_CONTEXT="${SUP_CONTEXT:-sp-gq}"
ARGO_NS="${ARGO_NS:-argocd-gq}"

K="kubectl --kubeconfig $VKS_KUBECONFIG"
$K apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: argocd-manager, namespace: kube-system}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: argocd-manager}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin}
subjects: [{kind: ServiceAccount, name: argocd-manager, namespace: kube-system}]
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations: {kubernetes.io/service-account.name: argocd-manager}
type: kubernetes.io/service-account-token
YAML

for i in $(seq 1 20); do
  TOKEN="$($K -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$TOKEN" ]] && break; sleep 2
done
[[ -n "$TOKEN" ]] || { echo "No obtuve el token del ServiceAccount"; exit 1; }
SERVER="$($K config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_DATA="$($K config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
echo "API del clúster VKS: $SERVER"

CONFIG="$(printf '{"bearerToken":"%s","tlsClientConfig":{"insecure":false,"caData":"%s"}}' "$TOKEN" "$CA_DATA")"
kubectl --context "$SUP_CONTEXT" -n "$ARGO_NS" create secret generic "cluster-$CLUSTER" \
  --from-literal=name="$CLUSTER" --from-literal=server="$SERVER" --from-literal=config="$CONFIG" \
  --dry-run=client -o yaml \
 | kubectl --context "$SUP_CONTEXT" label --local -f - argocd.argoproj.io/secret-type=cluster -o yaml \
 | kubectl --context "$SUP_CONTEXT" apply -f -
unset TOKEN CONFIG
echo "Clúster $CLUSTER registrado en Argo CD ($SUP_CONTEXT/$ARGO_NS). Verás el destino en Settings > Clusters."
