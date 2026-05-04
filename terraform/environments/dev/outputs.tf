# =============================================================================
# Outputs
# =============================================================================

# --- User Login ---

output "login_url" {
  description = "Cognito hosted UI login URL — send users here"
  value       = "https://${aws_cognito_user_pool_domain.gateway.domain}.auth.${local.region}.amazoncognito.com/login?client_id=${aws_cognito_user_pool_client.user_client.id}&response_type=code&scope=openid+email+profile&redirect_uri=${urlencode(var.callback_urls[0])}"
}

output "logout_url" {
  description = "Cognito hosted UI logout URL"
  value       = "https://${aws_cognito_user_pool_domain.gateway.domain}.auth.${local.region}.amazoncognito.com/logout?client_id=${aws_cognito_user_pool_client.user_client.id}&logout_uri=${urlencode(var.logout_urls[0])}"
}

output "token_endpoint" {
  description = "Cognito token endpoint — exchange auth code for tokens"
  value       = "https://${aws_cognito_user_pool_domain.gateway.domain}.auth.${local.region}.amazoncognito.com/oauth2/token"
}

output "user_client_id" {
  description = "Cognito user-facing client ID (public, for frontend apps)"
  value       = aws_cognito_user_pool_client.user_client.id
}

# --- Service Client (CI/CD, scripts) ---

output "service_client_id" {
  description = "Cognito service client ID (confidential, for machine-to-machine)"
  value       = aws_cognito_user_pool_client.service_client.id
}

output "service_client_secret" {
  description = "Cognito service client secret"
  value       = aws_cognito_user_pool_client.service_client.client_secret
  sensitive   = true
}

# --- Gateway ---

output "gateway_url" {
  description = "Single MCP endpoint — all tools, access controlled by Cedar policies"
  value       = aws_bedrockagentcore_gateway.unified.gateway_url
}

output "gateway_arn" {
  description = "Gateway ARN (used in Cedar policy resource references)"
  value       = aws_bedrockagentcore_gateway.unified.arn
}

# --- Policy ---

output "policy_engine_id" {
  description = "Policy Engine ID — use for adding/updating Cedar policies"
  value       = aws_bedrockagentcore_policy_engine.main.policy_engine_id
}

# --- Runtimes ---

output "orchestrator_runtime_arn" {
  description = "Orchestrator Runtime ARN"
  value       = module.orchestrator_runtime.runtime_arn
}

output "stackhawk_ecr_url" {
  description = "Push StackHawk wrapper image here"
  value       = module.stackhawk_runtime.ecr_repository_url
}

output "orchestrator_ecr_url" {
  description = "Push orchestrator image here"
  value       = module.orchestrator_runtime.ecr_repository_url
}

# --- Test Users ---

output "test_users" {
  description = "Pre-configured test users (set passwords via aws cognito-idp admin-set-user-password)"
  value = {
    security_engineer = "security-engineer@example.com"
    developer         = "developer@example.com"
    readonly          = "manager@example.com"
  }
}
