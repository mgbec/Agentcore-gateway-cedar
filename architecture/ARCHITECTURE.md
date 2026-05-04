# AgentCore Architecture: Single Gateway + Cedar Policy Engine

## Overview

One Gateway. One Cognito pool. One token. Cedar policies control per-user, per-tool access at the infrastructure level.

The Policy Engine evaluates Cedar policies on every `tools/call` request. Policies match on the user's JWT claims (role, username, scope, tier) and decide per-tool whether to allow or deny. Default is **deny** — if no `permit` policy matches, the call is blocked before it reaches the MCP server.

### Components

1. **Unified Gateway** — Single MCP endpoint with two targets (GitHub + StackHawk). Cognito JWT auth. Policy Engine attached.
2. **Policy Engine** — Cedar-based authorization. Evaluates policies per tool call against user claims.
3. **StackHawk Runtime** — Hosts the StackHawk MCP container. Fetches API key from Secrets Manager.
4. **Orchestrator Runtime** — Simple Strands agent. Connects to one Gateway URL. No auth logic, no tool filtering — policies handle it.

---

## Architecture Diagram

```
                     ┌──────────────────────────────────────┐
                     │          Orchestrator Agent           │
                     │   AgentCore Runtime (HTTP :8080)      │
                     │                                       │
                     │   One MCPClient, one Gateway URL      │
                     │   No tool filtering in code           │
                     └───────────────┬──────────────────────┘
                                     │
                        MCP/JSON-RPC │ + Cognito JWT
                                     │
                     ┌───────────────▼──────────────────────┐
                     │         Unified Gateway               │
                     │                                       │
                     │  Cognito JWT auth (single pool)       │
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
                     │    ├─ GitHubMCP (OAuth2)              │
                     │    └─ StackHawkMCP (IAM → Runtime)   │
                     └──────┬──────────────┬────────────────┘
                            │              │
                 OAuth2     │       IAM    │
                            │              │
              ┌─────────────▼──┐   ┌───────▼───────────────┐
              │  GitHub MCP    │   │  StackHawk Runtime     │
              │  (remote)      │   │  (MCP :8000, ARM64)    │
              │                │   │                        │
              │  github.com    │   │  API key from          │
              │  APIs          │   │  Secrets Manager       │
              └────────────────┘   └────────────────────────┘
```

---

## Access Control via Cedar Policies

### How it works

1. User authenticates with Cognito → gets a JWT with claims (role, username, etc.)
2. User calls a tool via the Gateway
3. Policy Engine extracts claims from the JWT
4. Cedar policies are evaluated:
   - **Action** = `TargetName___tool_name` (e.g., `StackHawkMCP___run_stackhawk_scan`)
   - **Principal** = the authenticated user with their tags/claims
   - **Resource** = the Gateway ARN
   - **Context** = the tool's input arguments
5. If any `permit` matches → tool call proceeds
6. If no `permit` matches → **DENY** (tool call never reaches the MCP server)

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

// Developers: GitHub tools + StackHawk triage only
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

// Block a specific user (emergency)
forbid(
  principal is AgentCore::OAuthUser,
  action,
  resource
)
when {
  principal.hasTag("username") &&
  principal.getTag("username") == "compromised-user"
};

// Input-level control: only allow scans on staging apps
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
```

### Role matrix

| Role | GitHub Tools | StackHawk Tools |
|------|-------------|-----------------|
| `security_engineer` | All | All 7 |
| `developer` | list_repos, get_issue, list_PRs, get_file, create_issue, create_PR | get_org_info, list_apps, get_findings |
| `readonly` | list_repos | get_org_info, list_apps |
| `qa_engineer` | None | run_scan, list_apps, get_findings |

### Adding a new role

One Terraform resource. No Gateway changes, no Runtime changes, no code changes:

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
          resource == AgentCore::Gateway::"${gateway_arn}"
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

`terraform apply`. Done.

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

## Why This Is Better

| Concern | Previous approach | Policy Engine approach |
|---------|------------------|----------------------|
| Per-tool access control | Proxy Runtimes or orchestrator code | Cedar policies (infrastructure-level) |
| Adding a new role | New Gateway + Cognito pool, or code change | One policy resource in Terraform |
| Number of Gateways | N (one per server or access level) | 1 |
| Number of Cognito pools | N | 1 |
| Orchestrator complexity | Token juggling, tool filtering, multi-client | One client, one URL, no filtering |
| Input-level restrictions | Not possible without custom code | `context.input.*` in Cedar |
| Emergency shutdown | Delete credentials or redeploy | One `forbid` policy, instant |
| Audit trail | Per-Gateway CloudWatch logs | Centralized policy evaluation logs |
| Default posture | Allow (unless you block) | Deny (unless you permit) |

---

## Terraform Structure

```
terraform/
├── modules/
│   └── mcp-runtime/          # ECR + IAM + Runtime (reusable)
├── environments/
│   └── dev/
│       ├── main.tf           # Gateway + Policy Engine + Cedar policies + Runtimes
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
├── containers/
│   ├── stackhawk-mcp/        # stdio→HTTP wrapper (Secrets Manager fetch)
│   └── orchestrator/         # Simple Strands agent (one Gateway client)
└── scripts/
    └── build-and-push.sh
```

---

## Deployment

```bash
cd terraform/environments/dev

# 1. Configure
cp terraform.tfvars.example terraform.tfvars

# 2. Create ECR repos
terraform init
terraform apply \
  -target=module.stackhawk_runtime.aws_ecr_repository.this \
  -target=module.orchestrator_runtime.aws_ecr_repository.this

# 3. Build ARM64 images
../../scripts/build-and-push.sh --env dev

# 4. Deploy everything (Gateway, Policy Engine, policies, Runtimes)
terraform apply
```

---

## Testing Policies

Use `LOG_ONLY` mode during development to see what would be denied without blocking:

```hcl
resource "aws_bedrockagentcore_gateway_policy" "main" {
  gateway_id        = aws_bedrockagentcore_gateway.unified.gateway_id
  policy_engine_arn = aws_bedrockagentcore_policy_engine.main.policy_engine_arn
  mode              = "LOG_ONLY"  # Switch to "ENFORCE" when ready
}
```

Check CloudWatch logs for policy evaluation results, then flip to `ENFORCE`.

---

## Cost

| Resource | Cost |
|----------|------|
| Gateway (1) | Per-invocation |
| Runtimes (2) | Per-session (idle timeout: 15 min) |
| Policy Engine (1) | Per-evaluation |
| Cognito (1 pool) | Free tier covers most dev usage |
| Secrets Manager (1) | $0.40/month |
| ECR (2 repos) | Storage + transfer |
