# GitHub Actions -> AWS with short-lived credentials (no stored access keys anywhere).
# GitHub mints an OIDC token per job; STS exchanges it for ~15-minute credentials for this role,
# but ONLY if the token's claims match the trust policy below.

locals {
  github_oidc_url = "token.actions.githubusercontent.com"
  github_oidc_arn = (var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
  : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.github_oidc_url}")

  # ID-qualified subject, e.g. repo:Shaho912@165518672/secure-ml-inference@1414836101:environment:production
  github_owner    = split("/", var.github_repo)[0]
  github_name     = split("/", var.github_repo)[1]
  github_oidc_sub = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repo_id}:environment:${var.github_environment}"
}

# AWS validates GitHub's certificate against its own trusted CAs, so no thumbprint is needed.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.github_oidc_url}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Exact match (not StringLike with wildcards): only jobs from THIS repo (by immutable ID)
    # running in the approval-gated "production" environment can assume the role. A PR, a fork,
    # a feature branch, another repo, or a recreated repo with the same name gets a different
    # `sub` and is refused. (The first deploy failed here with the name-only format; CloudTrail
    # showed the ID-qualified subject GitHub actually sends.)
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:sub"
      values   = [local.github_oidc_sub]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${var.project}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # AWS requires "*": this action has no resource-level permissions
  }
  statement {
    sid = "PushThisRepoOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"] # AWS requires "*": these actions have no resource-level permissions
  }
  statement {
    sid       = "DeployThisServiceOnly"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [aws_ecs_service.app.id]
  }
  statement {
    sid       = "PassOnlyThisProjectsTaskRolesToEcs"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, aws_iam_role.task.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-this-service-only"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
