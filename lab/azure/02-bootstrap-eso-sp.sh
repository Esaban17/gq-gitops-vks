#!/usr/bin/env bash
# Crea en el clúster VKS el Secret con las credenciales del service principal de ESO.
# Es el único secreto que se pone a mano (el "secreto cero"); todo lo demás lo trae ESO desde Key Vault.
# Uso:  KUBECONFIG=~/.kube/gq-apps-01.kubeconfig bash lab/azure/02-bootstrap-eso-sp.sh
set -euo pipefail
ENV_FILE="${ENV_FILE:-$(cd "$(dirname "$0")" && pwd)/.eso-sp.env}"
[[ -s "$ENV_FILE" ]] || { echo "Falta $ENV_FILE (corre 01-crear-keyvault.sh o créalo con AZ_CLIENT_ID y AZ_CLIENT_SECRET)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

kubectl get ns external-secrets >/dev/null 2>&1 || kubectl create ns external-secrets
kubectl -n external-secrets create secret generic azure-kv-sp \
  --from-literal=client-id="$AZ_CLIENT_ID" \
  --from-literal=client-secret="$AZ_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets label secret azure-kv-sp app.kubernetes.io/part-of=external-secrets --overwrite >/dev/null
echo "Secret external-secrets/azure-kv-sp listo en $(kubectl config current-context)."
