#!/usr/bin/env bash
# Crea en AWS lo que el diagrama pone en Azure (Key Vault + service principal), versión AWS:
#   - Secretos en AWS Secrets Manager bajo el prefijo gq-lab/ (JSON con varias llaves)
#   - Usuario IAM eso-gq-lab con política de SOLO LECTURA sobre gq-lab/* y un access key para ESO
# Requisitos: AWS CLI v2 (brew install awscli) y credenciales de admin de tu cuenta (aws configure / aws sso login).
# Uso:  bash lab/aws/01-crear-secretos.sh
# Salida: lab/aws/.eso-aws.env (600, en .gitignore) con el access key del usuario de ESO.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="${PREFIX:-gq-lab}"
IAM_USER="${IAM_USER:-eso-gq-lab}"
OUT="$(cd "$(dirname "$0")" && pwd)/.eso-aws.env"

[[ -s "$OUT" ]] && { echo "Ya existe $OUT. Bórralo si quieres recrear el access key."; exit 1; }
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
echo "== Cuenta $ACCOUNT  región $AWS_REGION"

rnd() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
upsert() {  # upsert <nombre> <json>
  if aws secretsmanager describe-secret --secret-id "$1" >/dev/null 2>&1; then
    aws secretsmanager put-secret-value --secret-id "$1" --secret-string "$2" >/dev/null
  else
    aws secretsmanager create-secret --name "$1" --secret-string "$2" \
      --description "Demo GitOps VKS (GQ LAB)" --tags Key=proyecto,Value=gq-lab >/dev/null
  fi
  echo "   $1"
}

echo "== Secretos de demo en Secrets Manager"
upsert "$PREFIX/portal-gq" "$(printf '{"db_user":"portal_app","db_password":"%s","api_key":"gq-%s","mensaje":"Hola desde AWS Secrets Manager (v1)"}' "$(rnd 24)" "$(rnd 32)")"

echo "== Usuario IAM $IAM_USER (solo lectura de $PREFIX/*)"
aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1 || aws iam create-user --user-name "$IAM_USER" --tags Key=proyecto,Value=gq-lab >/dev/null
aws iam put-user-policy --user-name "$IAM_USER" --policy-name eso-read-gq-lab --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
    "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT}:secret:${PREFIX}/*"
  }]
}
JSON
)"
KEY_JSON="$(aws iam create-access-key --user-name "$IAM_USER" --output json)"
umask 077
cat > "$OUT" <<ENV
AWS_REGION=$AWS_REGION
ESO_ACCESS_KEY_ID=$(echo "$KEY_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')
ESO_SECRET_ACCESS_KEY=$(echo "$KEY_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')
ENV
unset KEY_JSON

cat <<FIN

Listo. Access key del usuario de ESO guardado en: $OUT  (no lo subas a Git)
Si usaste una región distinta de us-east-1, cámbiala en deploy/platform/secret-stores/clustersecretstore-aws-sm.yaml.
Siguiente: lab/harbor/configurar-harbor.sh (guarda el robot de Harbor en $PREFIX/harbor-robot-portal-gq)
           y lab/aws/02-bootstrap-eso-creds.sh (crea el Secret aws-sm-creds en el clúster VKS).
FIN
