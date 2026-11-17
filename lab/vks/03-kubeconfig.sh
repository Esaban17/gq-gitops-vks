#!/usr/bin/env bash
# Extrae el kubeconfig de admin del clúster VKS desde el Supervisor.
# Uso:  vcf context use sp-gq ; bash lab/vks/03-kubeconfig.sh
set -euo pipefail
NS="${NS:-gq-apps}"; CLUSTER="${CLUSTER:-gq-apps-01}"
OUT="${OUT:-$HOME/.kube/$CLUSTER.kubeconfig}"
mkdir -p "$(dirname "$OUT")"
kubectl -n "$NS" get secret "$CLUSTER-kubeconfig" -o jsonpath='{.data.value}' | base64 -d > "$OUT"
chmod 600 "$OUT"
KUBECONFIG="$OUT" kubectl get nodes -o wide
echo "Kubeconfig en $OUT   ->  export KUBECONFIG=$OUT"
