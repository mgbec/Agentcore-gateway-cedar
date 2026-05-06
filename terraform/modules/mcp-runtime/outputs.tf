output "runtime_id" {
  description = "AgentCore Runtime ID"
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
}

output "runtime_arn" {
  description = "AgentCore Runtime ARN"
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
}

output "ecr_repository_url" {
  description = "ECR repository URL for this runtime's image"
  value       = aws_ecr_repository.this.repository_url
}

output "ecr_repository_arn" {
  description = "ECR repository ARN"
  value       = aws_ecr_repository.this.arn
}

output "execution_role_arn" {
  description = "IAM execution role ARN"
  value       = aws_iam_role.this.arn
}

output "mcp_endpoint_url" {
  description = "Runtime MCP invocation endpoint (for use as a Gateway target)"
  value       = "https://bedrock-agentcore.${data.aws_region.current.id}.amazonaws.com/runtimes/${urlencode(aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn)}/invocations"
}
