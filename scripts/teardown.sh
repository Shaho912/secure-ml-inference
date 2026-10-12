#!/usr/bin/env bash
# Tear down the main stack and verify nothing is left behind.
#
#   bash scripts/teardown.sh           # terraform destroy + clean up CI-registered task definitions + verify
#   bash scripts/teardown.sh --verify  # only check what still exists
#
# Why a script: CI registers new task-definition revisions on every deploy. Terraform only tracks
# the first one, so `terraform destroy` leaves the rest behind (free, but not "clean").
# The billing stack (infra/bootstrap) is left alone on purpose: it's free and should outlive this.
set -euo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash: keep /ecs/... paths intact

PROJECT="secure-ml-inference"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
aws_() { aws --region "$REGION" "$@"; }

verify() {
  echo "== Checking for leftovers in $REGION =="
  local left=0
  check() {  # check <label> <command...>; prints and counts non-empty results
    local label="$1"; shift
    local out
    out="$("$@" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')" || out=""
    if [ -n "$out" ] && [ "$out" != "None" ]; then
      echo "  LEFT  $label: $out"; left=$((left + 1))
    else
      echo "  clean $label"
    fi
  }
  check "ECS services"           aws_ ecs list-services --cluster "$PROJECT" --query 'serviceArns' --output text
  check "ECS cluster (ACTIVE)"   aws_ ecs describe-clusters --clusters "$PROJECT" --query "clusters[?status=='ACTIVE'].clusterName" --output text
  check "ECS task defs (ACTIVE)" aws_ ecs list-task-definitions --family-prefix "$PROJECT" --status ACTIVE --query 'taskDefinitionArns' --output text
  check "ECS task defs (INACTIVE)" aws_ ecs list-task-definitions --family-prefix "$PROJECT" --status INACTIVE --query 'taskDefinitionArns' --output text
  check "ECR repository"         aws_ ecr describe-repositories --repository-names "$PROJECT" --query 'repositories[].repositoryName' --output text
  check "Load balancer"          aws_ elbv2 describe-load-balancers --names "$PROJECT-alb" --query 'LoadBalancers[].LoadBalancerName' --output text
  check "Target group"           aws_ elbv2 describe-target-groups --names "$PROJECT-tg" --query 'TargetGroups[].TargetGroupName' --output text
  check "Secret"                 aws_ secretsmanager list-secrets --filters "Key=name,Values=$PROJECT/" --query 'SecretList[].Name' --output text
  check "Log group"              aws_ logs describe-log-groups --log-group-name-prefix "/ecs/$PROJECT" --query 'logGroups[].logGroupName' --output text
  check "Dashboard"              aws_ cloudwatch list-dashboards --dashboard-name-prefix "$PROJECT" --query 'DashboardEntries[].DashboardName' --output text
  check "VPC"                    aws_ ec2 describe-vpcs --filters "Name=tag:project,Values=$PROJECT" "Name=tag:stack,Values=main" --query 'Vpcs[].VpcId' --output text
  check "IAM roles"              aws iam list-roles --query "Roles[?starts_with(RoleName, '$PROJECT-')].RoleName" --output text
  check "GitHub OIDC provider"   aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" --output text
  # Anything else still carrying the main stack's tags. Stopped ECS tasks (:task/) are excluded:
  # they're records, not billable resources, and AWS expires them on its own.
  check "Other tagged resources" aws_ resourcegroupstaggingapi get-resources --tag-filters "Key=project,Values=$PROJECT" "Key=stack,Values=main" --query "ResourceTagMappingList[?!contains(ResourceARN, ':task/')].ResourceARN" --output text
  echo
  if [ "$left" -eq 0 ]; then echo "All clean: nothing from the main stack remains."; else echo "$left item type(s) remain (see LEFT above)."; fi
  return "$left"
}

if [ "${1:-}" != "--verify" ]; then
  echo "== terraform destroy (infra/main) =="
  terraform -chdir="$ROOT/infra/main" destroy

  echo "== Deregistering + deleting task-definition revisions registered by CI =="
  for arn in $(aws_ ecs list-task-definitions --family-prefix "$PROJECT" --status ACTIVE --query 'taskDefinitionArns' --output text); do
    aws_ ecs deregister-task-definition --task-definition "$arn" --query 'taskDefinition.revision' --output text >/dev/null
    echo "  deregistered $arn"
  done
  inactive=$(aws_ ecs list-task-definitions --family-prefix "$PROJECT" --status INACTIVE --query 'taskDefinitionArns' --output text)
  if [ -n "$inactive" ]; then
    # DeleteTaskDefinitions accepts at most 10 at a time.
    echo "$inactive" | tr '\t' '\n' | xargs -n 10 aws --region "$REGION" ecs delete-task-definitions \
      --query 'failures' --output text --task-definitions >/dev/null
    echo "  deleted inactive revisions (ECS removes them fully in the background)"
  fi
  echo
fi

verify
