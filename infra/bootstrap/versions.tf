terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Exact pin; Dependabot proposes bumps after a 14-day cooldown.
      version = "6.68.0"
    }
  }
  # State is local and gitignored. This stack is tiny and applied once by a human.
}

provider "aws" {
  # AWS publishes the EstimatedCharges billing metric ONLY in us-east-1.
  region = "us-east-1"

  default_tags {
    tags = {
      project = var.project
      env     = "shared"
      stack   = "bootstrap"
    }
  }
}
