# =============================================================================
# Dev Environment — Single Gateway + Policy Engine
#
# Architecture:
#   Orchestrator (HTTP Runtime)
#     └── Unified Gateway (Cognito + Cedar Policy Engine)
#           ├── Target: GitHub MCP (OAuth2)
#           └── Target: StackHawk MCP (IAM → Runtime)
#
# Access control:
#   Cedar policies control which users can call which tools.
#   One Gateway, one Cognito pool, one token — policies do the rest.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.id
  region     = data.aws_region.current.id
}

# =============================================================================
# 1. Secrets Manager — StackHawk API key
# =============================================================================

resource "aws_secretsmanager_secret" "stackhawk_api_key" {
  name                    = "${var.project_name}-stackhawk-api-key"
  description             = "StackHawk API key — fetched by wrapper at startup"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "stackhawk_api_key" {
  secret_id     = aws_secretsmanager_secret.stackhawk_api_key.id
  secret_string = var.stackhawk_api_key
}

# =============================================================================
# 2. StackHawk MCP Runtime
# =============================================================================

module "stackhawk_runtime" {
  source = "../../modules/mcp-runtime"

  name         = "stackhawk-mcp"
  project_name = var.project_name
  description  = "StackHawk MCP server — security scanning and triage"
  protocol     = "MCP"

  environment_variables = {
    STACKHAWK_API_KEY_SECRET_ARN = aws_secretsmanager_secret.stackhawk_api_key.arn
  }

  extra_iam_statements = [
    {
      Sid      = "ReadStackHawkSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.stackhawk_api_key.arn
    }
  ]
}

# =============================================================================
# 3. Cognito — Hosted UI with authorization code flow
#
# Users log in via the Cognito hosted page (or federated IdP).
# The JWT carries their custom:role attribute, which Cedar policies evaluate.
# =============================================================================

resource "aws_cognito_user_pool" "gateway" {
  name = "${var.project_name}-gateway-pool"

  # Users get custom attributes for role-based Cedar policies
  schema {
    name                = "role"
    attribute_data_type = "String"
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 64
    }
  }

  # Auto-verify email so users can log in immediately after confirmation
  auto_verified_attributes = ["email"]

  # Email configuration for verification codes
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  # Include custom:role in the ID token so Cedar policies can read it
  # (Cognito maps custom attributes to JWT claims automatically)

  tags = { Component = "Gateway" }
}

resource "aws_cognito_user_pool_domain" "gateway" {
  domain       = "${var.project_name}-gateway"
  user_pool_id = aws_cognito_user_pool.gateway.id
}

# Resource server for custom scopes (used by service-to-service clients)
resource "aws_cognito_resource_server" "gateway" {
  identifier   = "agentcore-gateway"
  name         = "AgentCore Gateway"
  user_pool_id = aws_cognito_user_pool.gateway.id

  scope {
    scope_name        = "invoke"
    scope_description = "Invoke gateway tools"
  }
}

# --- User-facing client (authorization code flow + hosted UI) ---
resource "aws_cognito_user_pool_client" "user_client" {
  name         = "${var.project_name}-user-client"
  user_pool_id = aws_cognito_user_pool.gateway.id

  generate_secret = false # Public client (SPA / native app)

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  # Token validity
  access_token_validity  = 15  # 15 minutes (short-lived)
  id_token_validity      = 15
  refresh_token_validity = 7   # 7 days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # Include custom:role in the token claims
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  prevent_user_existence_errors = "ENABLED"

  depends_on = [aws_cognito_resource_server.gateway]
}

# --- Service-to-service client (client credentials — for CI/CD, scripts) ---
resource "aws_cognito_user_pool_client" "service_client" {
  name         = "${var.project_name}-service-client"
  user_pool_id = aws_cognito_user_pool.gateway.id

  generate_secret = true

  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["agentcore-gateway/invoke"]
  supported_identity_providers         = ["COGNITO"]

  depends_on = [aws_cognito_resource_server.gateway]
}

# --- Pre-configured users for testing ---
resource "aws_cognito_user" "security_engineer" {
  user_pool_id = aws_cognito_user_pool.gateway.id
  username     = "security-engineer@example.com"

  attributes = {
    email          = "security-engineer@example.com"
    email_verified = "true"
    "custom:role"  = "security_engineer"
  }

  message_action = "SUPPRESS"
}

resource "aws_cognito_user" "developer" {
  user_pool_id = aws_cognito_user_pool.gateway.id
  username     = "developer@example.com"

  attributes = {
    email          = "developer@example.com"
    email_verified = "true"
    "custom:role"  = "developer"
  }

  message_action = "SUPPRESS"
}

resource "aws_cognito_user" "readonly" {
  user_pool_id = aws_cognito_user_pool.gateway.id
  username     = "manager@example.com"

  attributes = {
    email          = "manager@example.com"
    email_verified = "true"
    "custom:role"  = "readonly"
  }

  message_action = "SUPPRESS"
}

# =============================================================================
# 4. Unified Gateway — both MCP servers behind one endpoint
# =============================================================================

resource "aws_iam_role" "gateway" {
  name = "${var.project_name}-gateway-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

# Gateway needs to invoke the StackHawk Runtime
resource "aws_iam_role_policy" "gateway_invoke_runtime" {
  name = "InvokeStackHawkRuntime"
  role = aws_iam_role.gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeRuntime"
      Effect   = "Allow"
      Action   = "bedrock-agentcore:InvokeAgentRuntime"
      Resource = "${module.stackhawk_runtime.runtime_arn}*"
    }]
  })
}

resource "aws_bedrockagentcore_gateway" "unified" {
  name        = "${var.project_name}-gateway"
  description = "Unified MCP gateway — GitHub + StackHawk, access controlled by Cedar policies"
  role_arn    = aws_iam_role.gateway.arn

  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  protocol_configuration {
    mcp {
      search_type        = "SEMANTIC"
      supported_versions = ["2025-03-26"]
      instructions       = "Tools for GitHub (repos, issues, PRs) and StackHawk (security scanning, triage)."
    }
  }

  authorizer_configuration {
    custom_jwt_authorizer {
      allowed_clients = [
        aws_cognito_user_pool_client.user_client.id,
        aws_cognito_user_pool_client.service_client.id
      ]
      discovery_url = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.gateway.id}/.well-known/openid-configuration"
    }
  }

  tags = { Component = "Gateway" }
}

# --- Target 1: GitHub MCP (Authorization Code flow via AgentCore Identity) ---

# The GitHub MCP server requires Authorization Code flow (user-delegated access).
# This means:
#   1. Create a GitHub App (not OAuth App) at https://github.com/settings/apps
#   2. Create an AgentCore Identity OAuth2 credential provider with the GitHub App creds
#   3. Update the GitHub App's callback URL to the one from AgentCore Identity
#   4. The Gateway target references the credential provider
#   5. On first tools/call, the user is prompted to authorize via GitHub
#
# The credential provider handles token exchange, caching, and refresh.

resource "aws_bedrockagentcore_oauth2_credential_provider" "github" {
  name                       = "${replace(var.project_name, "-", "_")}_github_oauth"
  credential_provider_vendor = "GithubOauth2"

  oauth2_provider_config {
    github_oauth2_provider_config {
      client_id     = var.github_oauth_client_id
      client_secret = var.github_oauth_client_secret
    }
  }
}

# NOTE: After creating this resource, you must:
# 1. Get the callback URL from the credential provider:
#    aws bedrock-agentcore-control get-oauth2-credential-provider --name <name>
# 2. Update your GitHub App's "Authorization callback URL" to that value

resource "aws_bedrockagentcore_gateway_target" "github" {
  gateway_identifier = aws_bedrockagentcore_gateway.unified.gateway_id
  name               = "GitHubMCP"
  description        = "GitHub MCP server — Authorization Code flow (user-delegated)"

  target_configuration {
    mcp {
      mcp_server {
        endpoint = "https://api.githubcopilot.com/mcp/"
      }
    }
  }

  credential_provider_configuration {
    oauth {
      provider_arn = aws_bedrockagentcore_oauth2_credential_provider.github.credential_provider_arn
      scopes       = ["repo", "read:org", "read:user"]
      grant_type   = "AUTHORIZATION_CODE"
    }
  }
}

# --- Target 2: StackHawk MCP (IAM → Runtime) ---
resource "aws_bedrockagentcore_gateway_target" "stackhawk" {
  gateway_identifier = aws_bedrockagentcore_gateway.unified.gateway_id
  name               = "StackHawkMCP"
  description        = "StackHawk MCP server on AgentCore Runtime"

  target_configuration {
    mcp {
      mcp_server {
        endpoint = module.stackhawk_runtime.mcp_endpoint_url
      }
    }
  }

  credential_provider_configuration {
    gateway_iam_role {}
  }

  depends_on = [aws_iam_role_policy.gateway_invoke_runtime]
}

# =============================================================================
# 5. Policy Engine + Cedar Policies
#
# NOTE: As of AWS provider v6.43, the policy engine and policy resources
# are NOT yet available as Terraform resources. They must be managed via:
#   - AWS CLI: aws bedrock-agentcore-control create-policy-engine
#   - Python SDK: boto3 client("bedrock-agentcore-control")
#   - AgentCore CLI: agentcore gateway (policy commands)
#
# The policies below are documented as reference. Deploy them after
# terraform apply using the setup-policies.sh script.
# =============================================================================

# Policy Engine and Cedar policies are created via scripts/setup-policies.sh
# See architecture/ARCHITECTURE.md for the Cedar policy definitions.

# =============================================================================
# 6. Orchestrator Agent Runtime
# =============================================================================

module "orchestrator_runtime" {
  source = "../../modules/mcp-runtime"

  name         = "orchestrator"
  project_name = var.project_name
  description  = "Orchestrator agent — single Gateway, policy-controlled access"
  protocol     = "HTTP"

  environment_variables = {
    GATEWAY_MCP_URL = aws_bedrockagentcore_gateway.unified.gateway_url
  }

  extra_iam_statements = [
    {
      Sid      = "InvokeGateway"
      Effect   = "Allow"
      Action   = ["bedrock-agentcore:InvokeGateway"]
      Resource = aws_bedrockagentcore_gateway.unified.gateway_arn
    },
    {
      Sid    = "BedrockModels"
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      Resource = "*"
    }
  ]
}
