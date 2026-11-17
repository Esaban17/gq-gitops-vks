#!/usr/bin/env bash
# Crea en el namespace del Supervisor el Secret con la CA del Harbor regional para que los nodos del
# clúster VKS confíen en 10.2.20.7 al jalar imágenes (paso 7). Va ANTES de crear el clúster.
# Uso (contexto del Supervisor):  vcf context use sp-gq ; bash lab/vks/01-preparar-ca-harbor.sh
set -euo pipefail
NS="${NS:-gq-apps}"
CLUSTER="${CLUSTER:-gq-apps-01}"
HARBOR="${HARBOR:-10.2.20.7}"

# La API de Harbor entrega su CA en /api/v2.0/systeminfo/getcert
curl -skf "https://$HARBOR/api/v2.0/systeminfo/getcert" -o /tmp/harbor-ca.crt || true
if ! grep -q 'BEGIN CERTIFICATE' /tmp/harbor-ca.crt 2>/dev/null; then
  # Respaldo: último certificado de la cadena que presenta Harbor
  openssl s_client -connect "$HARBOR:443" -showcerts </dev/null 2>/dev/null \
    | awk '/BEGIN CERT/{buf=""} {buf=buf $0 "\n"} /END CERT/{last=buf} END{printf "%s", last}' > /tmp/harbor-ca.crt
fi
openssl x509 -in /tmp/harbor-ca.crt -noout -subject -issuer

# VKS espera el PEM codificado en base64 DOS veces (una la pone kubectl en data:, otra va aquí)
B64="$(base64 < /tmp/harbor-ca.crt | tr -d '\n')"
kubectl -n "$NS" create secret generic "$CLUSTER-user-trusted-ca-secret" \
  --from-literal=harbor-ca="$B64" --dry-run=client -o yaml | kubectl apply -f -
echo "Secret $NS/$CLUSTER-user-trusted-ca-secret listo."
