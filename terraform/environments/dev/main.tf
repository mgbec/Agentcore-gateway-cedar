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

# --- Target 1: GitHub MCP (OAuth2) ---
resource "aws_bedrockagentcore_gateway_target" "github" {
  gateway_identifier = aws_bedrockagentcore_gateway.unified.gateway_id
  name               = "GitHubMCP"
  description        = "GitHub MCP server — OAuth2 to GitHub"

  target_configuration {
    mcp_server_target {
      mcp_endpoint = "https://api.githubcopilot.com/mcp"
    }
  }

  credential_provider_configurations {
    credential_provider_type = "OAUTH"

    credential_provider {
      oauth_credential_provider {
        custom_oauth_provider {
          oauth_discovery {
            discovery_url = "https://github.com/login/oauth/.well-known/openid-configuration"
          }
          client_id     = var.github_oauth_client_id
          client_secret = var.github_oauth_client_secret
          scopes        = ["repo", "read:org", "read:user"]
        }
      }
    }
  }
}

# --- Target 2: StackHawk MCP (IAM → Runtime) ---
resource "aws_bedrockagentcore_gateway_target" "stackhawk" {
  gateway_identifier = aws_bedrockagentcore_gateway.unified.gateway_id
  name               = "StackHawkMCP"
  description        = "StackHawk MCP server on AgentCore Runtime"

  target_configuration {
    mcp_server_target {
      mcp_endpoint = module.stackhawk_runtime.mcp_endpoint_url
    }
  }

  credential_provider_configurations {
    credential_provider_type = "GATEWAY_IAM_ROLE"

    credential_provider {
      iam_credential_provider {
        service = "bedrock-agentcore"
        region  = local.region
      }
    }
  }

  depends_on = [aws_iam_role_policy.gateway_invoke_runtime]
}

# =============================================================================
# 5. Policy Engine + Cedar Policies
# =============================================================================

resource "aws_bedrockagentcore_policy_engine" "main" {
  name        = "${replace(var.project_name, "-", "_")}_policy_engine"
  description = "Cedar policy engine for tool-level access control"

  tags = { Component = "Policy" }
}

# Attach policy engine to gateway
resource "aws_bedrockagentcore_gateway_policy" "main" {
  gateway_id        = aws_bedrockagentcore_gateway.unified.gateway_id
  policy_engine_arn = aws_bedrockagentcore_policy_engine.main.policy_engine_arn
  mode              = "ENFORCE"
}

# --- Policy: Security engineers get all tools ---
resource "aws_bedrockagentcore_policy" "security_engineer_full_access" {
  name             = "security_engineer_full_access"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id
  description      = "Security engineers can use all GitHub and StackHawk tools"

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::OAuthUser,
          action,
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.unified.arn}"
        )
        when {
          principal.hasTag("role") &&
          principal.getTag("role") == "security_engineer"
        };
      CEDAR
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

# --- Policy: Developers get GitHub (all) + StackHawk (triage only) ---
resource "aws_bedrockagentcore_policy" "developer_github_full" {
  name             = "developer_github_full"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id
  description      = "Developers can use all GitHub tools"

  definition {
    cedar {
      statement = <<-CEDAR
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
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.unified.arn}"
        )
        when {
          principal.hasTag("role") &&
          principal.getTag("role") == "developer"
        };
      CEDAR
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

resource "aws_bedrockagentcore_policy" "developer_stackhawk_triage" {
  name             = "developer_stackhawk_triage"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id
  description      = "Developers can only triage StackHawk findings (no scanning or setup)"

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::OAuthUser,
          action in [
            AgentCore::Action::"StackHawkMCP___get_organization_info",
            AgentCore::Action::"StackHawkMCP___list_applications",
            AgentCore::Action::"StackHawkMCP___get_app_findings_for_triage"
          ],
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.unified.arn}"
        )
        when {
          principal.hasTag("role") &&
          principal.getTag("role") == "developer"
        };
      CEDAR
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

# --- Policy: Read-only users (managers) — discovery tools only ---
resource "aws_bedrockagentcore_policy" "readonly_discovery" {
  name             = "readonly_discovery"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id
  description      = "Read-only users can only view org info and app lists"

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::OAuthUser,
          action in [
            AgentCore::Action::"StackHawkMCP___get_organization_info",
            AgentCore::Action::"StackHawkMCP___list_applications",
            AgentCore::Action::"GitHubMCP___list_repos"
          ],
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.unified.arn}"
        )
        when {
          principal.hasTag("role") &&
          principal.getTag("role") == "readonly"
        };
      CEDAR
    }
  }

  validation_mode = "FAIL_ON_ANY_FINDINGS"
}

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
      Resource = aws_bedrockagentcore_gateway.unified.arn
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
