#!/usr/bin/env bash
# Crea en Azure lo que el diagrama pone a la izquierda (sin ACR ni Repos/Pipelines):
#   - Resource group + Azure Key Vault (modo RBAC, East US 2 como en el diagrama)
#   - Service principal de Entra ID para ESO con rol "Key Vault Secrets User" sobre el vault
#   - Secretos de demo de la app portal-gq
# Requisitos: Azure CLI (brew install azure-cli) y `az login` con tu cuenta gratis.
# Uso:  bash lab/azure/01-crear-keyvault.sh
# Salida: lab/azure/.eso-sp.env (permisos 600, en .gitignore) con tenant, client id y secret del SP.
set -euo pipefail

LOCATION="${LOCATION:-eastus2}"
RG="${RG:-rg-gq-lab-gitops}"
KV_NAME="${KV_NAME:-kv-gq-lab-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 5)}"
SP_NAME="${SP_NAME:-sp-eso-gq-lab}"
OUT="$(cd "$(dirname "$0")" && pwd)/.eso-sp.env"

[[ -s "$OUT" ]] && { echo "Ya existe $OUT. Bórralo si quieres recrear todo."; exit 1; }
az account show -o none 2>/dev/null || az login -o none

SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "== Suscripción $SUB_ID  tenant $TENANT_ID"

echo "== Registrando el proveedor Microsoft.KeyVault (solo la primera vez tarda)"
az provider register -n Microsoft.KeyVault --wait -o none

echo "== Resource group $RG ($LOCATION)"
az group create -n "$RG" -l "$LOCATION" -o none

echo "== Key Vault $KV_NAME (SKU standard, RBAC)"
az keyvault create -n "$KV_NAME" -g "$RG" -l "$LOCATION" --sku standard \
  --enable-rbac-authorization true --retention-days 7 -o none
KV_ID="$(az keyvault show -n "$KV_NAME" --query id -o tsv)"
KV_URL="$(az keyvault show -n "$KV_NAME" --query properties.vaultUri -o tsv)"

echo "== Rol 'Key Vault Secrets Officer' para tu usuario (para poder escribir secretos)"
ME="$(az ad signed-in-user show --query id -o tsv)"
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope "$KV_ID" -o none

echo "== Service principal $SP_NAME con 'Key Vault Secrets User' (solo lectura de secretos)"
SP_JSON="$(az ad sp create-for-rbac -n "$SP_NAME" --role "Key Vault Secrets User" --scopes "$KV_ID" --years 1 -o json)"
CLIENT_ID="$(echo "$SP_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["appId"])')"
CLIENT_SECRET="$(echo "$SP_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')"

umask 077
cat > "$OUT" <<ENV
AZ_TENANT_ID=$TENANT_ID
AZ_KV_NAME=$KV_NAME
AZ_KV_URL=$KV_URL
AZ_CLIENT_ID=$CLIENT_ID
AZ_CLIENT_SECRET=$CLIENT_SECRET
ENV
unset SP_JSON CLIENT_SECRET

echo "== Secretos de demo (reintenta mientras propaga el RBAC, 1-3 min)"
rnd() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
put() {
  for i in $(seq 1 18); do
    az keyvault secret set --vault-name "$KV_NAME" -n "$1" --value "$2" -o none 2>/dev/null && { echo "   $1"; return; }
    sleep 10
  done
  echo "No pude escribir $1 (¿RBAC aún sin propagar?). Reintenta: az keyvault secret set --vault-name $KV_NAME -n $1 --value ..."; exit 1
}
put portal-gq-db-user     "portal_app"
put portal-gq-db-password "$(rnd 24)"
put portal-gq-api-key     "gq-$(rnd 32)"
put portal-gq-mensaje     "Hola desde Azure Key Vault (v1)"

cat <<FIN

Listo. Datos para el repo (no son secretos):
  vaultUrl: ${KV_URL}
  tenantId: ${TENANT_ID}
Ponlos en deploy/platform/secret-stores/clustersecretstore-azure-kv.yaml (o pásamelos y abro el PR).

Credenciales del SP de ESO guardadas en: $OUT  (no lo subas a Git)
Siguiente: lab/harbor/configurar-harbor.sh (guarda el robot de Harbor en este vault)
           y lab/azure/02-bootstrap-eso-sp.sh (crea el Secret azure-kv-sp en el clúster VKS).
FIN
