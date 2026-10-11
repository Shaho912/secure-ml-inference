# Two task roles, both trusted only by ECS tasks in THIS account (aws:SourceAccount blocks the
# cross-account "confused deputy" problem).
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# ---------- Execution role: used by the ECS agent (not your code) to start the task ----------
# Replaces the AWS-managed AmazonECSTaskExecutionRolePolicy (which allows any repo / log group /
# secret) with permissions scoped to this project's resources only.
resource "aws_iam_role" "execution" {
  name               = "${var.project}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # AWS requires "*": this action has no resource-level permissions
  }
  statement {
    sid       = "PullThisRepoOnly"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.app.arn]
  }
  statement {
    sid       = "WriteThisLogGroupOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
  statement {
    sid       = "ReadThisSecretOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.api_key.arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "least-privilege-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# ---------- Task role: what the app code itself can call ----------
# Intentionally has NO permissions: the app calls no AWS APIs. If the container were
# compromised, the credentials it could reach would be useless.
resource "aws_iam_role" "task" {
  name               = "${var.project}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}
