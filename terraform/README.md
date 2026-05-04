# AgentCore MCP Architecture — Single Gateway + Cedar Policies + User Login

## Architecture

```
User → Cognito Hosted UI (login) → JWT with custom:role claim
  → Client App → Orchestrator (forwards JWT)
    → Unified Gateway (validates JWT, evaluates Cedar policies)
      ├── Target: GitHub MCP (OAuth2)
      └── Target: StackHawk MCP (IAM → Runtime)
```

One Gateway. One Cognito pool. Cedar policies control per-user, per-tool access.

## User Login Flow

1. User visits the **login URL** (Cognito hosted UI)
2. User authenticates (email/password, or federated IdP)
3. Cognito redirects to your app's callback URL with an authorization code
4. Your app exchanges the code for tokens at the token endpoint
5. Your app sends the `id_token` (JWT) to the orchestrator with each request
6. The orchestrator forwards the JWT to the Gateway
7. The Policy Engine evaluates Cedar policies against the JWT's `custom:role` claim
8. Allowed tool calls proceed; denied calls return an auth error

## Two Client Types

| Client | Flow | Use Case |
|--------|------|----------|
| `user_client` | Authorization code (hosted UI) | End users logging in via browser |
| `service_client` | Client credentials | CI/CD pipelines, scripts, service-to-service |

Both are accepted by the Gateway's JWT authorizer.

## Quick Start

```bash
cd environments/dev

# 1. Configure
cp terraform.tfvars.example terraform.tfvars

# 2. Deploy ECR repos first (images must exist before Runtimes can reference them)
terraform init
terraform apply \
  -target=module.stackhawk_runtime.aws_ecr_repository.this \
  -target=module.orchestrator_runtime.aws_ecr_repository.this

# 3. Build ARM64 container images and push to ECR
../../scripts/build-and-push.sh --env dev

# 4. Deploy everything else (Gateway, Policy Engine, Runtimes, Cognito)
terraform apply

# 3. Set passwords for test users
POOL_ID=$(terraform output -raw cognito_pool_id 2>/dev/null || terraform output -json | jq -r '.login_url.value' | grep -oP 'pool/\K[^/]+')
aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username "developer@example.com" \
  --password "DevPass123!" \
  --permanent

# 4. Get the login URL
terraform output login_url
```

## Testing the Login Flow

```bash
# 1. Open the login URL in a browser
open "$(terraform output -raw login_url)"

# 2. Log in as developer@example.com / DevPass123!

# 3. Cognito redirects to your callback URL with ?code=XXXXX

# 4. Exchange the code for tokens
TOKEN_ENDPOINT=$(terraform output -raw token_endpoint)
CLIENT_ID=$(terraform output -raw user_client_id)

curl -X POST "$TOKEN_ENDPOINT" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code&client_id=$CLIENT_ID&code=XXXXX&redirect_uri=http://localhost:3000/callback"

# 5. Use the id_token to invoke the orchestrator
RUNTIME_ARN=$(terraform output -raw orchestrator_runtime_arn)
aws bedrock-agentcore invoke-agent-runtime \
  --agent-runtime-arn "$RUNTIME_ARN" \
  --payload '{"prompt": "List my GitHub repos", "token": "<id_token>"}'
```

## Adding Users

```bash
# Create a new user with a role
aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username "qa@example.com" \
  --user-attributes Name=email,Value=qa@example.com Name=custom:role,Value=qa_engineer \
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username "qa@example.com" \
  --password "QaPass123!" \
  --permanent
```

Then add a Cedar policy for the `qa_engineer` role in Terraform.

## Adding a New Role

One Terraform resource, no infra changes:

```hcl
resource "aws_bedrockagentcore_policy" "qa_engineer" {
  name             = "qa_engineer_access"
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::OAuthUser,
          action in [
            AgentCore::Action::"StackHawkMCP___run_stackhawk_scan",
            AgentCore::Action::"StackHawkMCP___list_applications",
            AgentCore::Action::"StackHawkMCP___get_app_findings_for_triage"
          ],
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.unified.arn}"
        )
        when {
          principal.hasTag("role") &&
          principal.getTag("role") == "qa_engineer"
        };
      CEDAR
    }
  }
}
```

## Token Security

- Access tokens expire in **15 minutes** (configurable)
- Refresh tokens last 7 days
- The orchestrator never stores tokens — it's a stateless relay
- The Gateway validates JWT signatures against Cognito's JWKS
- Cedar policies are evaluated server-side on every tool call

## Cleanup

```bash
terraform destroy
```
