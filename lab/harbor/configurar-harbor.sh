#!/usr/bin/env bash
# Configura el Harbor regional (10.2.20.7) como en el diagrama:
#   - Proyecto privado gq-apps
#   - Endpoint de registro hacia GHCR (con un PAT de GitHub de solo lectura de paquetes)
#   - Regla de réplica PULL programada: ghcr.io/<owner>/portal-gq -> gq-apps/portal-gq (paso 4)
#   - Cuenta robot de solo pull para el imagePullSecret (paso 7), guardada en Azure Key Vault
# Requisitos: curl, jq; az logueado si quieres que guarde el robot en Key Vault.
# Uso:  bash lab/harbor/configurar-harbor.sh
set -euo pipefail

HARBOR="${HARBOR:-https://10.2.20.7}"
PROJECT="${PROJECT:-gq-apps}"
GH_OWNER="${GH_OWNER:-esaban17}"           # en minúsculas, como lo publica GHCR
IMAGE="${IMAGE:-portal-gq}"
CRON="${CRON:-0 */5 * * * *}"              # cron de Harbor (6 campos): cada 5 minutos
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/azure/.eso-sp.env"

read -rp  "Usuario admin de Harbor [admin]: " H_USER; H_USER="${H_USER:-admin}"
read -rsp "Password de $H_USER en Harbor: " H_PASS; echo
read -rp  "Usuario de GitHub para GHCR [Esaban17]: " GH_USER; GH_USER="${GH_USER:-Esaban17}"
read -rsp "PAT de GitHub (classic, scope read:packages): " GH_PAT; echo

api() { curl -sk -u "$H_USER:$H_PASS" -H 'Content-Type: application/json' "$@"; }
code() { curl -sk -o /dev/null -w '%{http_code}' -u "$H_USER:$H_PASS" -H 'Content-Type: application/json' "$@"; }

[[ "$(code "$HARBOR/api/v2.0/users/current")" == 200 ]] || { echo "Login a Harbor falló"; exit 1; }

echo "== Proyecto privado $PROJECT"
if api "$HARBOR/api/v2.0/projects?name=$PROJECT" | jq -e ".[]?|select(.name==\"$PROJECT\")" >/dev/null; then
  echo "   ya existe"
else
  api -X POST "$HARBOR/api/v2.0/projects" -d "{\"project_name\":\"$PROJECT\",\"metadata\":{\"public\":\"false\"}}"
fi

echo "== Endpoint GHCR"
TYPE="$(api "$HARBOR/api/v2.0/replication/adapters" | jq -r '.[]' | grep -x 'github-ghcr' || true)"
TYPE="${TYPE:-docker-registry}"
echo "   tipo de adaptador: $TYPE"
REG_ID="$(api "$HARBOR/api/v2.0/registries?q=name%3Dghcr" | jq -r '.[0].id // empty')"
if [[ -z "$REG_ID" ]]; then
  api -X POST "$HARBOR/api/v2.0/registries" -d "$(jq -n --arg t "$TYPE" --arg u "$GH_USER" --arg p "$GH_PAT" \
    '{name:"ghcr",type:$t,url:"https://ghcr.io",insecure:false,credential:{type:"basic",access_key:$u,access_secret:$p}}')"
  REG_ID="$(api "$HARBOR/api/v2.0/registries?q=name%3Dghcr" | jq -r '.[0].id')"
fi
unset GH_PAT
echo "   registry id $REG_ID"
api -X POST "$HARBOR/api/v2.0/registries/ping" -d "{\"id\":$REG_ID}" -w '   ping HTTP %{http_code}\n' -o /dev/null

echo "== Regla de réplica pull programada ($CRON)"
POL_ID="$(api "$HARBOR/api/v2.0/replication/policies?name=ghcr-$IMAGE" | jq -r '.[0].id // empty')"
POLICY="$(jq -n --argjson r "$REG_ID" --arg ns "$PROJECT" --arg n "$GH_OWNER/$IMAGE" --arg c "$CRON" --arg name "ghcr-$IMAGE" '{
  name:$name, description:"Replica pull programada GHCR -> Harbor (paso 4 del diagrama)",
  src_registry:{id:$r}, dest_namespace:$ns, dest_namespace_replace_count:1,
  filters:[{type:"name",value:$n},{type:"tag",value:"sha-*"}],
  trigger:{type:"scheduled",trigger_settings:{cron:$c}},
  enabled:true, override:true, speed:-1, copy_by_chunk:false}')"
if [[ -z "$POL_ID" ]]; then
  api -X POST "$HARBOR/api/v2.0/replication/policies" -d "$POLICY"
  POL_ID="$(api "$HARBOR/api/v2.0/replication/policies?name=ghcr-$IMAGE" | jq -r '.[0].id')"
else
  api -X PUT "$HARBOR/api/v2.0/replication/policies/$POL_ID" -d "$POLICY"
fi
echo "   policy id $POL_ID"

echo "== Cuenta robot de solo pull"
ROBOT_JSON="$(api -X POST "$HARBOR/api/v2.0/robots" -d "$(jq -n --arg ns "$PROJECT" --arg n "$IMAGE-pull" '{
  name:$n, description:"imagePullSecret de portal-gq en VKS", duration:-1, level:"project",
  permissions:[{kind:"project",namespace:$ns,access:[{resource:"repository",action:"pull"}]}]}')")"
R_NAME="$(echo "$ROBOT_JSON" | jq -r '.name // empty')"
R_SECRET="$(echo "$ROBOT_JSON" | jq -r '.secret // empty')"
if [[ -z "$R_NAME" ]]; then
  echo "   No se creó el robot (¿ya existe?). Respuesta: $(echo "$ROBOT_JSON" | jq -c .errors 2>/dev/null)"
  echo "   Para regenerar: Harbor > Projects > $PROJECT > Robot Accounts > Refresh secret."
else
  echo "   robot: $R_NAME"
  if [[ -s "$ENV_FILE" ]] && command -v az >/dev/null && az account show -o none 2>/dev/null; then
    KV="$(grep ^AZ_KV_NAME= "$ENV_FILE" | cut -d= -f2)"
    az keyvault secret set --vault-name "$KV" -n harbor-robot-portal-gq-user     --value "$R_NAME"   -o none
    az keyvault secret set --vault-name "$KV" -n harbor-robot-portal-gq-password --value "$R_SECRET" -o none
    echo "   guardado en Key Vault $KV (harbor-robot-portal-gq-user / -password)"
  else
    echo "   No encontré az/.eso-sp.env. Guárdalo tú en Key Vault:"
    echo "     az keyvault secret set --vault-name <vault> -n harbor-robot-portal-gq-user --value '$R_NAME'"
    echo "     az keyvault secret set --vault-name <vault> -n harbor-robot-portal-gq-password --value '<secret>'"
    umask 077; echo "$R_SECRET" > "$(dirname "$0")/.robot-secret"; echo "   (secret en $(dirname "$0")/.robot-secret, bórralo después)"
  fi
fi
unset R_SECRET H_PASS

echo "== Primera ejecución manual de la réplica"
api -X POST "$HARBOR/api/v2.0/replication/executions" -d "{\"policy_id\":$POL_ID}" -w '   HTTP %{http_code}\n' -o /dev/null
echo "Revisa en Harbor > Administration > Replications. Si aún no hay imagen en GHCR, la ejecución sale vacía: es normal."
