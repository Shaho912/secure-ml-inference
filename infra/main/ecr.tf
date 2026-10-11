# Private image registry.
# IMMUTABLE tags: a pushed :<git-sha> can never be overwritten, so a tag always means one image.
# force_delete: `terraform destroy` removes the repo even when it still holds images.
# Encryption: AES-256 (default, free). A customer-managed KMS key (Trivy AWS-0033, LOW) adds
# $1/month for no practical gain in this demo.
resource "aws_ecr_repository" "app" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true # ECR basic scanning (free), a second opinion alongside Trivy in CI
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 5 most recent images (storage is billed per GB-month)"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
