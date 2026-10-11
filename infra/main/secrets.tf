# The API key the app requires on POST /predict.
# Terraform creates only the secret *container*. Set the value yourself with the CLI, so it never
# appears in Terraform state or in the repo:
#   aws secretsmanager put-secret-value --secret-id <secret_name output> --secret-string "<key>"
# ECS injects it into the container as the API_KEY env var at task start.
#
# recovery_window_in_days = 0: delete immediately on destroy (default is a 7-30 day recovery
# window, which would block re-creating a secret with the same name).
# Encryption: the AWS-managed key (free). A customer-managed key (Trivy AWS-0098, LOW) costs $1/month.
resource "aws_secretsmanager_secret" "api_key" {
  name                    = "${var.project}/api-key"
  description             = "X-API-Key value required by POST /predict"
  recovery_window_in_days = 0
}
