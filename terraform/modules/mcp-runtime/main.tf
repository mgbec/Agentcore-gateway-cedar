# =============================================================================
# Reusable MCP Runtime Module
#
# Creates: ECR repo, IAM execution role, AgentCore Runtime
# Inputs:  protocol (MCP/HTTP), env vars, extra IAM statements
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.id
  region     = data.aws_region.current.id
  # AgentCore runtime names must be alphanumeric + underscores
  runtime_name = replace("${var.project_name}_${var.name}", "-", "_")
}

# -----------------------------------------------------------------------------
# ECR Repository
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  name                 = "${var.project_name}-${var.name}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true

  tags = merge(var.tags, {
    Name      = "${var.project_name}-${var.name}"
    Component = var.name
  })
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# -----------------------------------------------------------------------------
# IAM Execution Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "this" {
  name = "${var.project_name}-${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AgentCoreAssume"
      Effect = "Allow"
      Principal = {
        Service = "bedrock-agentcore.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:bedrock-agentcore:${local.region}:${local.account_id}:*"
        }
      }
    }]
  })

  tags = merge(var.tags, { Component = var.name })
}

resource "aws_iam_role_policy" "this" {
  name = "${var.name}-execution-policy"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        # ECR pull
        {
          Sid    = "ECRImageAccess"
          Effect = "Allow"
          Action = [
            "ecr:BatchGetImage",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchCheckLayerAvailability"
          ]
          Resource = aws_ecr_repository.this.arn
        },
        {
          Sid      = "ECRToken"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*"
        },
        # CloudWatch Logs
        {
          Sid    = "Logs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:DescribeLogGroups",
            "logs:DescribeLogStreams",
            "logs:PutLogEvents"
          ]
          Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"
        },
        # X-Ray
        {
          Sid    = "XRay"
          Effect = "Allow"
          Action = [
            "xray:PutTraceSegments",
            "xray:PutTelemetryRecords",
            "xray:GetSamplingRules",
            "xray:GetSamplingTargets"
          ]
          Resource = "*"
        },
        # CloudWatch Metrics
        {
          Sid      = "Metrics"
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = "*"
          Condition = {
            StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" }
          }
        },
        # Workload identity tokens
        {
          Sid    = "WorkloadIdentity"
          Effect = "Allow"
          Action = [
            "bedrock-agentcore:GetWorkloadAccessToken",
            "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
            "bedrock-agentcore:GetWorkloadAccessTokenForUserId"
          ]
          Resource = [
            "arn:aws:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
            "arn:aws:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/workload-identity/*"
          ]
        }
      ],
      var.extra_iam_statements
    )
  })
}

# -----------------------------------------------------------------------------
# AgentCore Runtime
# -----------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = local.runtime_name
  description        = var.description
  role_arn           = aws_iam_role.this.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.this.repository_url}:${var.image_tag}"
    }
  }

  network_configuration {
    network_mode = var.network_mode
  }

  protocol_configuration {
    server_protocol = var.protocol
  }

  environment_variables = merge(
    {
      AWS_REGION         = local.region
      AWS_DEFAULT_REGION = local.region
    },
    var.environment_variables
  )

  depends_on = [aws_iam_role_policy.this]

  tags = merge(var.tags, {
    Name      = "${var.project_name}-${var.name}"
    Component = var.name
  })
}
