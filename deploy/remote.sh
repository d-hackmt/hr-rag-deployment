#!/usr/bin/env bash
# Runs ON the EC2 instance, sent there by the GitHub Actions workflow via
# AWS Systems Manager (SSM) - never over SSH. The workflow fills in the
# ${...} placeholders below with real values before sending it.
#
#   IMAGE          full ECR image URI incl. tag  (e.g. 1234.dkr.ecr.eu-west-2.amazonaws.com/hr-assistant:<sha>)
#   REGISTRY       ECR registry host             (e.g. 1234.dkr.ecr.eu-west-2.amazonaws.com)
#   AWS_REGION     e.g. eu-west-2
#   SSM_ENV_PARAM  SSM Parameter Store name that holds the runtime .env  (e.g. /hr-assistant/env)
set -euo pipefail

APP_DIR=/opt/hr-assistant
CONTAINER=hr-assistant
PORT=8501

mkdir -p "$APP_DIR"

echo "==> Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo "==> Fetching runtime secrets from SSM Parameter Store"
aws ssm get-parameter \
  --name "${SSM_ENV_PARAM}" \
  --with-decryption \
  --region "${AWS_REGION}" \
  --query 'Parameter.Value' --output text > "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

echo "==> Pulling new image: ${IMAGE}"
docker pull "${IMAGE}"

echo "==> Restarting container"
docker rm -f "$CONTAINER" 2>/dev/null || true
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  -p "${PORT}:${PORT}" \
  --env-file "$APP_DIR/.env" \
  "${IMAGE}"

echo "==> Cleaning up old images"
docker image prune -f

echo "==> Health check"
curl -fsS --retry 20 --retry-delay 3 --retry-all-errors \
  "http://localhost:${PORT}/_stcore/health"
echo

echo "==> Deployed OK: ${IMAGE}"
