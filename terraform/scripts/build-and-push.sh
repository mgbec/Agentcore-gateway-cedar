#!/usr/bin/env bash
# =============================================================================
# Build ARM64 container images and push to ECR
#
# Usage: ./scripts/build-and-push.sh [--env dev]
#
# Reads ECR URLs from Terraform outputs in the specified environment.
# Requires: docker (with buildx), aws cli, terraform
# =============================================================================

set -euo pipefail

ENV="${2:-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_DIR="${ROOT_DIR}/environments/${ENV}"
CONTAINERS_DIR="${ROOT_DIR}/containers"

if [ ! -d "$ENV_DIR" ]; then
  echo "Error: environment directory not found: $ENV_DIR"
  exit 1
fi

# Read outputs from Terraform
REGION=$(terraform -chdir="$ENV_DIR" output -raw aws_region 2>/dev/null || aws configure get region || echo "us-west-2")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> Region: ${REGION}"
echo "==> Account: ${ACCOUNT_ID}"
echo ""

echo "==> Logging in to ECR..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

# --- StackHawk MCP ---
STACKHAWK_REPO=$(terraform -chdir="$ENV_DIR" output -raw stackhawk_ecr_url)
echo "==> Building StackHawk MCP wrapper (ARM64)..."
docker buildx build \
  --platform linux/arm64 \
  -t "${STACKHAWK_REPO}:latest" \
  --push \
  "${CONTAINERS_DIR}/stackhawk-mcp"
echo "    Pushed: ${STACKHAWK_REPO}:latest"

# --- Orchestrator ---
ORCHESTRATOR_REPO=$(terraform -chdir="$ENV_DIR" output -raw orchestrator_ecr_url)
echo "==> Building Orchestrator agent (ARM64)..."
docker buildx build \
  --platform linux/arm64 \
  -t "${ORCHESTRATOR_REPO}:latest" \
  --push \
  "${CONTAINERS_DIR}/orchestrator"
echo "    Pushed: ${ORCHESTRATOR_REPO}:latest"

echo ""
echo "==> Done. Run 'terraform -chdir=${ENV_DIR} apply' to deploy."
