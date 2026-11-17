#!/usr/bin/env bash
# Crea en el clúster VKS el Secret con el access key del usuario IAM de ESO.
# Es el único secreto que se pone a mano (el "secreto cero"); lo demás lo trae ESO desde Secrets Manager.
# Uso:  KUBECONFIG=~/.kube/gq-apps-01.kubeconfig bash lab/aws/02-bootstrap-eso-creds.sh
set -euo pipefail
ENV_FILE="${ENV_FILE:-$(cd "$(dirname "$0")" && pwd)/.eso-aws.env}"
[[ -s "$ENV_FILE" ]] || { echo "Falta $ENV_FILE (corre 01-crear-secretos.sh)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

kubectl get ns external-secrets >/dev/null 2>&1 || kubectl create ns external-secrets
kubectl -n external-secrets create secret generic aws-sm-creds \
  --from-literal=access-key-id="$ESO_ACCESS_KEY_ID" \
  --from-literal=secret-access-key="$ESO_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret external-secrets/aws-sm-creds listo en $(kubectl config current-context)."
