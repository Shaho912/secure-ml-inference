output "app_url" {
  description = "Public URL of the service (HTTP)."
  value       = "http://${aws_lb.app.dns_name}"
}

output "secret_name" {
  description = "Set its value once: aws secretsmanager put-secret-value --secret-id <this> --secret-string <key>"
  value       = aws_secretsmanager_secret.api_key.name
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

# Copy these into GitHub: Settings -> Secrets and variables -> Actions -> Variables.
# They're identifiers, not secrets: the deploy role can only be assumed by this repo's
# production environment via OIDC, so knowing its ARN grants nothing.
output "github_actions_variables" {
  value = {
    AWS_REGION          = var.region
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.github_deploy.arn
    ECR_REPOSITORY_URL  = aws_ecr_repository.app.repository_url
    ECS_CLUSTER         = aws_ecs_cluster.main.name
    ECS_SERVICE         = aws_ecs_service.app.name
    ECS_TASK_FAMILY     = aws_ecs_task_definition.app.family
    ECS_CONTAINER_NAME  = local.container_name
    APP_URL             = "http://${aws_lb.app.dns_name}"
  }
}
