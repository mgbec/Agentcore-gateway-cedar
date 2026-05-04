variable "name" {
  description = "Short name for this runtime (used in resource naming)"
  type        = string
}

variable "project_name" {
  description = "Project-level prefix for resource naming"
  type        = string
}

variable "description" {
  description = "Human-readable description of the runtime"
  type        = string
  default     = ""
}

variable "protocol" {
  description = "Server protocol: MCP or HTTP"
  type        = string
  default     = "MCP"

  validation {
    condition     = contains(["MCP", "HTTP"], var.protocol)
    error_message = "Must be MCP or HTTP."
  }
}

variable "network_mode" {
  description = "Network mode: PUBLIC or VPC"
  type        = string
  default     = "PUBLIC"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  default     = "latest"
}

variable "environment_variables" {
  description = "Environment variables for the runtime container"
  type        = map(string)
  default     = {}
}

variable "extra_iam_statements" {
  description = "Additional IAM policy statements for the execution role (JSON-encoded list)"
  type        = list(any)
  default     = []
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
