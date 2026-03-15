#!/usr/bin/env bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
AWS_ACCOUNT_ID="192440504332"
AWS_REGION="us-east-1"
ECR_REPO="abyss-server"
ECS_CLUSTER="abyss"
ECS_SERVICE="abyss-server"
TASK_FAMILY="abyss-server"
IMAGE_TAG="${1:-latest}"

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Preflight checks ───────────────────────────────────────────────
for cmd in aws docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found" >&2
    exit 1
  fi
done

echo "==> Verifying AWS identity..."
aws sts get-caller-identity --region "$AWS_REGION" || {
  echo "ERROR: AWS credentials not configured" >&2
  exit 1
}

# ── 1. Build Docker image ──────────────────────────────────────────
echo ""
echo "==> Building Docker image (tag: ${IMAGE_TAG})..."
docker build -t "${ECR_REPO}:${IMAGE_TAG}" "${REPO_ROOT}/server"

# ── 2. Login to ECR ────────────────────────────────────────────────
echo ""
echo "==> Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ── 3. Tag & push ──────────────────────────────────────────────────
echo ""
echo "==> Pushing ${ECR_URI}:${IMAGE_TAG}..."
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:${IMAGE_TAG}"

# ── 4. Register task definition ────────────────────────────────────
echo ""
echo "==> Registering task definition..."
TASK_DEF_ARN=$(aws ecs register-task-definition \
  --region "$AWS_REGION" \
  --cli-input-json "file://${REPO_ROOT}/infra/ecs/task-definition.json" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)
echo "    Registered: ${TASK_DEF_ARN}"

# ── 5. Update ECS service ──────────────────────────────────────────
echo ""
echo "==> Updating ECS service..."
aws ecs update-service \
  --region "$AWS_REGION" \
  --cluster "$ECS_CLUSTER" \
  --service "$ECS_SERVICE" \
  --task-definition "$TASK_FAMILY" \
  --force-new-deployment \
  --query 'service.serviceName' \
  --output text

# ── 6. Wait for stability ──────────────────────────────────────────
echo ""
echo "==> Waiting for service to stabilize (this may take a few minutes)..."
aws ecs wait services-stable \
  --region "$AWS_REGION" \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE"

echo ""
echo "==> Deploy complete! Service is stable."
echo "    Task definition: ${TASK_DEF_ARN}"
echo "    Image: ${ECR_URI}:${IMAGE_TAG}"
