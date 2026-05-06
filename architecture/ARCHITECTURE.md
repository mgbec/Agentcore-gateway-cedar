# AgentCore Architecture: Single Gateway + Cedar Policy Engine

## Overview

One Gateway. One Cognito pool. One token. Cedar policies control per-user, per-tool access at the infrastructure level.

The Policy Engine evaluates Cedar policies on every `tools/call` request. Policies match on the user's JWT claims (role, username, scope, tier) and decide per-tool whether to allow or deny. Default is **deny** — if no `permit` policy matches, the call is blocked before it reaches the MCP server.

### Components

1. **Unified Gateway** — Single MCP endpoint with two targets (GitHub + StackHawk). Cognito JWT auth. Policy Engine attached.
2. **Policy Engine** — Cedar-based authorization. Evaluates policies per tool call against user claims. Managed via AWS CLI (not yet in Terraform provider).
3. **StackHawk Runtime** — Hosts the StackHawk MCP container. Fetches API key from Secrets Manager at startup.
4. **Orchestrator Runtime** — Simple Strands agent. Connects to one Gateway URL. Forwards user JWT. No auth logic, no tool filtering — policies handle it.
5. **Cognito Hosted UI** — User login page. Issues JWTs with `custom:role` claim that Cedar policies evaluate.

---

## Architecture Diagram

```
User
  │
  ▼
Cognito Hosted UI (login)
  │
  │ authorization code → token exchange
  ▼
Client App (your frontend)
  │
  │ JWT (id_token with custom:role)
  ▼
┌──────────────────────────────────────┐
│          Orchestrator Agent           │
│   AgentCore Runtime (HTTP :8080)      │
│                                       │
│   Forwards user JWT to Gateway        │
│   No tool filtering in code           │
└───────────────┬──────────────────────┘
                │
   MCP/JSON-RPC │ + user's JWT
                │
┌───────────────▼──────────────────────┐
│         Unified Gateway               │
│                                       │
│  Cognito JWT validation               │
│  Semantic search across all tools     │
│                                       │
│  ┌─────────────────────────────────┐ │
│  │      Cedar Policy Engine         │ │
│  │                                   │ │
│  │  Evaluates on every tools/call:  │ │
│  │  WHO (principal claims/tags)      │ │
│  │  × WHAT (TargetName___tool_name) │ │
│  │  × WHERE (gateway ARN)           │ │
│  │  × INPUTS (context.input.*)      │ │
│  │                                   │ │
│  │  Default: DENY                    │ │
│  └─────────────────────────────────┘ │
│                                       │
│  Targets:                             │
│    ├─ GitHubMCP (OAuth2 credential    │
│    │   provider → GitHub APIs)        │
│    └─ StackHawkMCP (IAM → Runtime)   │
└──────┬──────────────┬────────────────┘
       │              │
OAuth2 │       IAM    │
       │              │
┌──────▼───────┐   ┌──▼────────────────────┐
│  GitHub MCP  │   │  StackHawk Runtime     │
│  (remote)    │   │  (MCP :8000, ARM64)    │
│              │   │                        │
│  github.com  │   │  API key from          │
│  APIs        │   │  Secrets Manager       │
└──────────────┘   └────────────────────────┘
```

---

## User Login Flow

1. User visits the Cognito hosted UI login page
2. Authenticates with email/password (or federated IdP)
3. Cognito redirects to your app's callback URL with an authorization code
4. Your app exchanges the code for tokens (id_token, access_token, refresh_token)
5. Your app sends the `id_token` to the orchestrator with each request
6. Orchestrator forwards the JWT to the Gateway
7. Gateway validates the JWT signature against Cognito's JWKS
8. Policy Engine evaluates Cedar policies against the JWT's `custom:role` claim
9. Allowed tool calls proceed; denied calls return an authorization error

---

## Access Control via Cedar Policies

### How it works

- **Action** = `TargetName___tool_name` (e.g., `StackHawkMCP___run_stackhawk_scan`)
- **Principal** = the authenticated user with their JWT claims as tags
- **Resource** = the Gateway ARN
- **Context** = the tool's input arguments

### Example policies

```cedar
// Security engineers: full access to everything
permit(
  principal is AgentCore::OAuthUser,
  action,
  resource == AgentCore::Gateway::"arn:aws:bedrock-agentcore:us-west-2:123:gateway/gw-id"
)
when {
  principal.hasTag("role") &&
  principal.getTag("role") == "security_engineer"
};

// Developers: StackHawk triage only (no scanning or setup)
permit(
  principal is AgentCore::OAuthUser,
  action in [
    AgentCore::Action::"StackHawkMCP___get_organization_info",
    AgentCore::Action::"StackHawkMCP___list_applications",
    AgentCore::Action::"StackHawkMCP___get_app_findings_for_triage"
  ],
  resource == AgentCore::Gateway::"arn:aws:bedrock-agentcore:us-west-2:123:gateway/gw-id"
)
when {
  principal.hasTag("role") &&
  principal.getTag("role") == "developer"
};

// Input-level control: only allow scans on staging hosts
permit(
  principal is AgentCore::OAuthUser,
  action == AgentCore::Action::"StackHawkMCP___run_stackhawk_scan",
  resource == AgentCore::Gateway::"arn:aws:bedrock-agentcore:us-west-2:123:gateway/gw-id"
)
when {
  principal.hasTag("role") &&
  principal.getTag("role") == "developer" &&
  context.input has host &&
  context.input.host like "*staging*"
};

// Emergency: block a compromised user
forbid(
  principal is AgentCore::OAuthUser,
  action,
  resource
)
when {
  principal.hasTag("username") &&
  principal.getTag("username") == "compromised-user"
};
```

### Role matrix

| Role | GitHub Tools | StackHawk Tools |
|------|-------------|-----------------|
| `security_engineer` | All | All 7 |
| `developer` | list_repos, get_issue, list_PRs, get_file, create_issue, create_PR | get_org_info, list_apps, get_findings |
| `readonly` | list_repos | get_org_info, list_apps |
| `qa_engineer` | None | run_scan, list_apps, get_findings |

### Adding a new role

One AWS CLI command. No Gateway changes, no Runtime changes, no code changes, no redeployment.

---

## StackHawk MCP — Tool Inventory

| Phase | Tool Name (Cedar action) | Description |
|-------|--------------------------|-------------|
| Discover | `StackHawkMCP___get_organization_info` | Get org details, teams, apps |
| Discover | `StackHawkMCP___list_applications` | List applications |
| Setup | `StackHawkMCP___setup_stackhawk_for_project` | Generate `stackhawk.yml` |
| Validate | `StackHawkMCP___validate_stackhawk_config` | Validate YAML config |
| Validate | `StackHawkMCP___validate_field_exists` | Anti-hallucination check |
| Scan | `StackHawkMCP___run_stackhawk_scan` | Run security scan |
| Triage | `StackHawkMCP___get_app_findings_for_triage` | Get findings for remediation |

---

## Terraform Implementation Notes

### What's in Terraform (provider v6.43)

- Cognito user pool, domain, clients, test users
- AgentCore Gateway with JWT authorizer
- Gateway targets (GitHub MCP + StackHawk MCP)
- OAuth2 credential provider for GitHub
- AgentCore Runtimes (StackHawk MCP + Orchestrator)
- ECR repositories, IAM roles, Secrets Manager

### What's NOT in Terraform (managed via AWS CLI)

- Policy Engine creation
- Cedar policy creation and updates
- Policy Engine attachment to Gateway

These are managed by `scripts/setup-policies.sh` which runs after `terraform apply`. The AWS provider will likely add these resources in a future version.

---

## Deployment Steps

```bash
cd terraform/environments/dev

# 1. Configure variables
cp terraform.tfvars.example terraform.tfvars

# 2. Create ECR repos (images must exist before Runtimes)
terraform init
terraform apply \
  -target=module.stackhawk_runtime.aws_ecr_repository.this \
  -target=module.orchestrator_runtime.aws_ecr_repository.this

# 3. Build and push ARM64 container images
../../scripts/build-and-push.sh --env dev

# 4. Deploy all infrastructure
terraform apply

# 5. Create Policy Engine and Cedar policies
../../scripts/setup-policies.sh --env dev

# 6. Set passwords for test users
# (see terraform/README.md for commands)
```

---

## Updating Cedar Policies

**Via AWS CLI (immediate, no deploy needed):**
```bash
aws bedrock-agentcore-control create-policy \
  --policy-engine-id "..." \
  --name "new_role_policy" \
  --definition '{"cedar":{"statement":"..."}}'
```

**Via natural language (generates Cedar for you):**
```python
policy_client.generate_policy(
    policy_engine_id="...",
    name="block_prod_scans",
    resource={"arn": gateway_arn},
    content={"rawText": "Block developers from running scans on production hosts"}
)
```

**Testing before enforcing:**
Set the Policy Engine to `LOG_ONLY` mode. All calls are allowed, but decisions are logged to CloudWatch. Review logs, fix policies, then switch to `ENFORCE`.

---

## Cost

| Resource | Cost Model |
|----------|-----------|
| Gateway (1) | Per-invocation |
| Runtimes (2) | Per-session (idle timeout: 15 min) |
| Policy Engine (1) | Per-evaluation |
| Cognito (1 pool) | Free tier covers most dev usage |
| Secrets Manager (1) | $0.40/month |
| ECR (2 repos) | Storage + transfer |
| OAuth2 credential provider (1) | Included with Gateway |
