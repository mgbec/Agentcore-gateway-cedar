#!/usr/bin/env bash
# =============================================================================
# Create Policy Engine and Cedar policies for the AgentCore Gateway
#
# Run this AFTER terraform apply (the Gateway must exist first).
#
# Usage: ./scripts/setup-policies.sh [--env dev]
#
# Requires: aws cli, jq, terraform
# =============================================================================

set -euo pipefail

ENV="${2:-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_DIR="${ROOT_DIR}/environments/${ENV}"

# Get Gateway ARN from Terraform outputs
GATEWAY_ARN=$(terraform -chdir="$ENV_DIR" output -raw gateway_arn)
GATEWAY_ID=$(terraform -chdir="$ENV_DIR" output -raw gateway_url | grep -oP '[^/]+(?=\.gateway)')
REGION=$(aws configure get region || echo "us-west-2")

echo "==> Gateway ARN: $GATEWAY_ARN"
echo "==> Region: $REGION"
echo ""

# --- 1. Create Policy Engine ---
echo "==> Creating Policy Engine..."
POLICY_ENGINE=$(aws bedrock-agentcore-control create-policy-engine \
  --name "agentcore_mcp_policy_engine" \
  --description "Cedar policy engine for tool-level access control" \
  --region "$REGION" \
  2>/dev/null || true)

if [ -z "$POLICY_ENGINE" ]; then
  echo "    Policy engine may already exist, fetching..."
  POLICY_ENGINE_ID=$(aws bedrock-agentcore-control list-policy-engines \
    --region "$REGION" \
    --query "policyEngines[?name=='agentcore_mcp_policy_engine'].policyEngineId" \
    --output text)
else
  POLICY_ENGINE_ID=$(echo "$POLICY_ENGINE" | jq -r '.policyEngineId')
fi

echo "    Policy Engine ID: $POLICY_ENGINE_ID"

# --- 2. Attach Policy Engine to Gateway ---
echo "==> Attaching Policy Engine to Gateway..."
aws bedrock-agentcore-control update-gateway \
  --gateway-identifier "$GATEWAY_ID" \
  --policy-config "{\"policyEngineArn\":\"arn:aws:bedrock-agentcore:${REGION}:$(aws sts get-caller-identity --query Account --output text):policy-engine/${POLICY_ENGINE_ID}\",\"mode\":\"ENFORCE\"}" \
  --region "$REGION" \
  2>/dev/null || echo "    (may already be attached)"

# --- 3. Create Cedar Policies ---
echo "==> Creating Cedar policies..."

# Security engineer: full access
cat <<CEDAR | aws bedrock-agentcore-control create-policy \
  --policy-engine-id "$POLICY_ENGINE_ID" \
  --name "security_engineer_full_access" \
  --description "Security engineers can use all tools" \
  --definition "{\"cedar\":{\"statement\":\"$(cat | tr '\n' ' ')\"}}" \
  --region "$REGION" 2>/dev/null || echo "    (policy may already exist)"
permit(
  principal is AgentCore::OAuthUser,
  action,
  resource == AgentCore::Gateway::"${GATEWAY_ARN}"
)
when {
  principal.hasTag("role") &&
  principal.getTag("role") == "security_engineer"
};
CEDAR

# Developer: GitHub full + StackHawk triage
cat <<CEDAR | aws bedrock-agentcore-control create-policy \
  --policy-engine-id "$POLICY_ENGINE_ID" \
  --name "developer_github_full" \
  --description "Developers can use all GitHub tools" \
  --definition "{\"cedar\":{\"statement\":\"$(cat | tr '\n' ' ')\"}}" \
  --region "$REGION" 2>/dev/null || echo "    (policy may already exist)"
permit(
  principal is AgentCore::OAuthUser,
  action in [
    AgentCore::Action::"GitHubMCP___list_repos",
    AgentCore::Action::"GitHubMCP___get_issue",
    AgentCore::Action::"GitHubMCP___list_pull_requests",
    AgentCore::Action::"GitHubMCP___get_file_contents",
    AgentCore::Action::"GitHubMCP___create_issue",
    AgentCore::Action::"GitHubMCP___create_pull_request"
  ],
  resource == AgentCore::Gateway::"${GATEWAY_ARN}"
)
when {
  principal.hasTag("role") &&
  principal.getTag("role") == "developer"
};
CEDAR

cat <<CEDAR | aws bedrock-agentcore-control create-policy \
  --policy-engine-id "$POLICY_ENGINE_ID" \
  --name "developer_stackhawk_triage" \
  --description "Developers can only triage StackHawk findings" \
  --definition "{\"cedar\":{\"statement\":\"$(cat | tr '\n' ' ')\"}}" \
  --region "$REGION" 2>/dev/null || echo "    (policy may already exist)"
permit(
  principal is AgentCore::OAuthUser,
  action in [
    AgentCore::Action::"StackHawkMCP___get_organization_info",
    AgentCore::Action::"StackHawkMCP___list_applications",
    AgentCore::Action::"StackHawkMCP___get_app_findings_for_triage"
  ],
  resource == AgentCore::Gateway::"${GATEWAY_ARN}"
)
when {
  principal.hasTag("role") &&
  principal.getTag("role") == "developer"
};
CEDAR

# Read-only: discovery only
cat <<CEDAR | aws bedrock-agentcore-control create-policy \
  --policy-engine-id "$POLICY_ENGINE_ID" \
  --name "readonly_discovery" \
  --description "Read-only users can only view org info and app lists" \
  --definition "{\"cedar\":{\"statement\":\"$(cat | tr '\n' ' ')\"}}" \
  --region "$REGION" 2>/dev/null || echo "    (policy may already exist)"
permit(
  principal is AgentCore::OAuthUser,
  action in [
    AgentCore::Action::"StackHawkMCP___get_organization_info",
    AgentCore::Action::"StackHawkMCP___list_applications",
    AgentCore::Action::"GitHubMCP___list_repos"
  ],
  resource == AgentCore::Gateway::"${GATEWAY_ARN}"
)
when {
  principal.hasTag("role") &&
  principal.getTag("role") == "readonly"
};
CEDAR

echo ""
echo "==> Done. Policy Engine and Cedar policies are configured."
echo "    Policies are in ENFORCE mode."
