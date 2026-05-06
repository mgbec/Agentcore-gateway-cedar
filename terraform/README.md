# AgentCore MCP Architecture — Single Gateway + Cedar Policies + User Login

## Architecture

```
User → Cognito Hosted UI (login) → JWT with custom:role claim
  → Client App → Orchestrator (forwards JWT)
    → Unified Gateway (validates JWT, evaluates Cedar policies)
      ├── Target: GitHub MCP (OAuth2 via credential provider)
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
cd terraform/environments/dev

# 1. Configure (see "Configuration" section below for details)
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

## Configuration

The `terraform.tfvars` file contains all the secrets and settings for your deployment. It's gitignored — never commit it.

### Step 1: Copy the example file

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
```

### Step 2: Get your GitHub App credentials

The GitHub MCP server uses **Authorization Code flow** (user-delegated access), which requires a **GitHub App** (not a classic OAuth App).

1. Go to [github.com/settings/apps](https://github.com/settings/apps)
2. Click **"New GitHub App"**
3. Fill in:
   - **GitHub App name:** `AgentCore Gateway GitHub MCP`
   - **Homepage URL:** `http://localhost:3000`
   - **Authorization callback URL:** `https://example.com/auth` (you'll update this after deploy)
4. Under **Permissions**, set what you need (e.g., Repository: Read & Write)
5. Click **"Create GitHub App"**
6. Copy the **Client ID** (not the App ID) → paste into `github_oauth_client_id`
7. Click **"Generate a new client secret"** → paste into `github_oauth_client_secret`

**After `terraform apply`**, you must update the callback URL:
```bash
# Get the callback URL from AgentCore Identity
aws bedrock-agentcore-control get-oauth2-credential-provider \
  --name agentcore_mcp_github_oauth --region us-west-2

# Copy the callback URL from the output, then go to:
# https://github.com/settings/apps → your app → Edit
# Update "Authorization callback URL" to the AgentCore Identity callback URL
```

This is a one-time step. After that, when a user calls a GitHub tool for the first time, they'll be prompted to authorize via GitHub in their browser.

### Step 3: Get your StackHawk API key

1. Go to [app.stackhawk.com](https://app.stackhawk.com) (sign up for free if needed)
2. Navigate to **Settings → API Keys**
   - On the Vibe plan, the key is shown on the main page
3. Generate a new API key (starts with `hawk.`)
4. Paste into `stackhawk_api_key`

### Step 4: Set callback URLs

These tell Cognito where to redirect after login. Must match your frontend app.

For local development (default):
```hcl
callback_urls = ["http://localhost:3000/callback"]
logout_urls   = ["http://localhost:3000"]
```

For a deployed app:
```hcl
callback_urls = ["https://myapp.example.com/callback"]
logout_urls   = ["https://myapp.example.com"]
```

You can list multiple URLs (e.g., both local and deployed):
```hcl
callback_urls = ["http://localhost:3000/callback", "https://myapp.example.com/callback"]
logout_urls   = ["http://localhost:3000", "https://myapp.example.com"]
```

### Step 5: (Optional) Change region or project name

```hcl
aws_region   = "us-east-1"       # default: us-west-2
project_name = "my-project"      # default: agentcore-mcp
```

Changing `project_name` after initial deploy will recreate all resources.

### Your final terraform.tfvars should look like:

```hcl
aws_region   = "us-west-2"
project_name = "agentcore-mcp"

github_oauth_client_id     = "Iv1.a1b2c3d4e5f6g7h8"
github_oauth_client_secret = "abcdef1234567890abcdef1234567890abcdef12"

stackhawk_api_key = "hawk.xxxxxxxxxxxxxxxxxxxxxxxxxxxx"

callback_urls = ["http://localhost:3000/callback"]
logout_urls   = ["http://localhost:3000"]
```

---

## Deploy

## Deploy

```bash
cd terraform/environments/dev

# 2. Initialize Terraform
terraform init

# 3. Create ECR repos first (images must exist before Runtimes can reference them)
terraform apply \
  -target=module.stackhawk_runtime.aws_ecr_repository.this \
  -target=module.orchestrator_runtime.aws_ecr_repository.this

# 4. Build ARM64 container images and push to ECR
../../scripts/build-and-push.sh --env dev

# 5. Deploy everything else (Gateway, Cognito, Runtimes)
terraform apply

# 6. Set up Cedar policies (not yet in TF provider — uses AWS CLI)
../../scripts/setup-policies.sh --env dev

# 7. Set passwords for test users
POOL_ID=$(aws cognito-idp list-user-pools --max-results 10 \
  --query "UserPools[?Name=='agentcore-mcp-gateway-pool'].Id" --output text)

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username "security-engineer@example.com" \
  --password "SecEng123!" --permanent

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username "developer@example.com" \
  --password "DevPass123!" --permanent

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username "manager@example.com" \
  --password "Manager123!" --permanent
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
aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username "qa@example.com" \
  --user-attributes Name=email,Value=qa@example.com Name=custom:role,Value=qa_engineer \
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL_ID" \
  --username "qa@example.com" \
  --password "QaPass123!" --permanent
```

Then add a Cedar policy for the `qa_engineer` role via `setup-policies.sh` or the AWS CLI.

## Adding a New Role (Cedar Policy)

Since the Policy Engine isn't yet in the Terraform AWS provider, add policies via the CLI:

```bash
POLICY_ENGINE_ID="<from setup-policies.sh output>"
GATEWAY_ARN=$(terraform output -raw gateway_arn)

aws bedrock-agentcore-control create-policy \
  --policy-engine-id "$POLICY_ENGINE_ID" \
  --name "qa_engineer_access" \
  --description "QA engineers can run scans and view findings" \
  --definition '{
    "cedar": {
      "statement": "permit(principal is AgentCore::OAuthUser, action in [AgentCore::Action::\"StackHawkMCP___run_stackhawk_scan\", AgentCore::Action::\"StackHawkMCP___list_applications\", AgentCore::Action::\"StackHawkMCP___get_app_findings_for_triage\"], resource == AgentCore::Gateway::\"'$GATEWAY_ARN'\") when { principal.hasTag(\"role\") && principal.getTag(\"role\") == \"qa_engineer\" };"
    }
  }' \
  --region us-west-2
```

No Gateway changes, no Runtime changes, no code changes, no redeployment.

## Adding a New MCP Server

1. If it needs hosting, add a `module "xxx_runtime"` block in `main.tf`
2. Add a `aws_bedrockagentcore_gateway_target` resource pointing to it
3. If it needs OAuth2, create an `aws_bedrockagentcore_oauth2_credential_provider`
4. Add Cedar policies for who can use its tools
5. `terraform apply` + update policies via CLI

## Token Security

- Access tokens expire in **15 minutes**
- Refresh tokens last 7 days
- The orchestrator never stores tokens — stateless relay
- The Gateway validates JWT signatures against Cognito's JWKS
- Cedar policies are evaluated server-side on every tool call
- Default posture is **deny** — no permit policy = no access

## Structure

```
terraform/
├── modules/
│   └── mcp-runtime/              # Reusable: ECR + IAM + Runtime
├── environments/
│   └── dev/
│       ├── main.tf               # Gateway + Cognito + Targets + Runtimes
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── terraform.tfvars.example
├── containers/
│   ├── stackhawk-mcp/            # stdio→HTTP wrapper (Secrets Manager)
│   └── orchestrator/             # Strands agent (JWT relay)
└── scripts/
    ├── build-and-push.sh         # Build ARM64 images → ECR
    └── setup-policies.sh         # Create Policy Engine + Cedar policies (AWS CLI)
```

## Cleanup

```bash
cd terraform/environments/dev
terraform destroy
```

Note: The Policy Engine and Cedar policies must be deleted separately via the AWS CLI or console before destroying the Gateway.
