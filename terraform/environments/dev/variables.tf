variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "agentcore-mcp"
}

# --- GitHub OAuth ---
variable "github_oauth_client_id" {
  description = "GitHub OAuth App client ID"
  type        = string
  sensitive   = true
}

variable "github_oauth_client_secret" {
  description = "GitHub OAuth App client secret"
  type        = string
  sensitive   = true
}

# --- StackHawk ---
variable "stackhawk_api_key" {
  description = "StackHawk platform API key"
  type        = string
  sensitive   = true
}

# --- User Auth ---
variable "callback_urls" {
  description = "OAuth2 callback URLs for the hosted login UI (e.g., your frontend app)"
  type        = list(string)
  default     = ["http://localhost:3000/callback"]
}

variable "logout_urls" {
  description = "URLs to redirect to after logout"
  type        = list(string)
  default     = ["http://localhost:3000"]
}
