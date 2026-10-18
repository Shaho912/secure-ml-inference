terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.67.0" # exact pin; Dependabot proposes bumps after a 14-day cooldown
    }
  }
  # State is local and gitignored: CI never runs Terraform (it only pushes images and
  # updates the ECS service), so there is no second writer that would need shared state.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project = var.project
      env     = var.env
      stack   = "main"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
