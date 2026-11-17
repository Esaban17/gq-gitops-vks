#!/usr/bin/env bash
# ECR como registro de CI (equivale al ACR del diagrama) y sus dos identidades:
#   - Repositorio ECR privado "portal-gq" (tags inmutables, escaneo al subir, retiene las últimas 20 imágenes)
#   - GitHub Actions -> AWS por OIDC (sin llaves estáticas): rol gha-ecr-push-gq-lab que solo puede
#     hacer push a ese repo y solo desde la rama main de Esaban17/gq-gitops-vks  (paso 2)
#   - Usuario IAM harbor-ecr-pull-gq-lab de solo lectura para la réplica pull de Harbor (equivale al
#     SP de Harbor con AcrPull)  (paso 4)
# Uso:  AWS_PROFILE=<perfil> bash lab/aws/03-crear-ecr.sh
# Salida: lab/aws/.harbor-ecr.env (600, en .gitignore) con el access key de Harbor.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
REPO="${REPO:-portal-gq}"
GH_REPO="${GH_REPO:-Esaban17/gq-gitops-vks}"
ROLE="${ROLE:-gha-ecr-push-gq-lab}"
HARBOR_USER="${HARBOR_USER:-harbor-ecr-pull-gq-lab}"
OUT="$(cd "$(dirname "$0")" && pwd)/.harbor-ecr.env"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REPO_ARN="arn:aws:ecr:${AWS_REGION}:${ACCOUNT}:repository/${REPO}"
echo "== Cuenta $ACCOUNT  región $AWS_REGION"

echo "== Repositorio ECR $REPO"
if ! aws ecr describe-repositories --repository-names "$REPO" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "$REPO" --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true --tags Key=proyecto,Value=gq-lab >/dev/null
fi
aws ecr put-lifecycle-policy --repository-name "$REPO" --lifecycle-policy-text '{
  "rules":[{"rulePriority":1,"description":"Conservar las ultimas 20 imagenes",
  "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},
  "action":{"type":"expire"}}]}' >/dev/null
echo "   ${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO}"

echo "== Proveedor OIDC de GitHub Actions"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
fi

echo "== Rol $ROLE (solo push a $REPO, solo desde $GH_REPO@main)"
TRUST="$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"$OIDC_ARN"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{
   "StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com",
                   "token.actions.githubusercontent.com:sub":"repo:${GH_REPO}:ref:refs/heads/main"}}}]}
JSON
)"
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$TRUST"
else
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" \
    --description "GitHub Actions push a ECR $REPO (GQ LAB)" --tags Key=proyecto,Value=gq-lab >/dev/null
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name ecr-push-portal-gq --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart",
   "ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:DescribeImages"],
  "Resource":"$REPO_ARN"}]}
JSON
)"
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE}"

echo "== Usuario IAM $HARBOR_USER (solo lectura de ECR, para la réplica de Harbor)"
aws iam get-user --user-name "$HARBOR_USER" >/dev/null 2>&1 || aws iam create-user --user-name "$HARBOR_USER" --tags Key=proyecto,Value=gq-lab >/dev/null
aws iam put-user-policy --user-name "$HARBOR_USER" --policy-name ecr-pull-gq-lab --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ecr:GetAuthorizationToken","ecr:DescribeRepositories"],"Resource":"*"},
 {"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer",
   "ecr:DescribeImages","ecr:ListImages"],"Resource":"$REPO_ARN"}]}
JSON
)"
if [[ -s "$OUT" ]]; then
  echo "   ya existe $OUT; no creo otro access key"
else
  KEY_JSON="$(aws iam create-access-key --user-name "$HARBOR_USER" --output json)"
  umask 077
  cat > "$OUT" <<ENV
AWS_REGION=$AWS_REGION
ECR_REGISTRY=${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
HARBOR_ECR_ACCESS_KEY_ID=$(echo "$KEY_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')
HARBOR_ECR_SECRET_ACCESS_KEY=$(echo "$KEY_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')
ENV
  unset KEY_JSON
fi

echo "== Variable AWS_ROLE_ARN en GitHub"
if command -v gh >/dev/null && gh variable set AWS_ROLE_ARN -R "$GH_REPO" -b "$ROLE_ARN" 2>/dev/null; then
  echo "   AWS_ROLE_ARN configurada en $GH_REPO"
else
  echo "   No pude usar gh. Créala a mano: $GH_REPO > Settings > Secrets and variables > Actions >"
  echo "   Variables > New repository variable:  AWS_ROLE_ARN = $ROLE_ARN"
fi

cat <<FIN

Listo.
  Registro ECR:   ${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPO}
  Rol de CI:      $ROLE_ARN
  Llave Harbor:   $OUT  (no la subas a Git)
Siguiente: bash lab/harbor/configurar-harbor.sh   (crea el endpoint ECR y la regla de réplica)
FIN
