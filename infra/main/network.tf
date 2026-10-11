# VPC with two public subnets (an ALB requires at least two AZs) and NO NAT gateway.
# Tasks run in public subnets with a public IP so they can pull from ECR and reach Secrets
# Manager/CloudWatch without a ~$32/month NAT gateway. Inbound traffic to tasks is still limited
# to the ALB security group. See README "Known limitations" for the private-subnet upgrade path.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Trivy AWS-0178 (VPC flow logs) is MEDIUM, so it doesn't gate CI. It's skipped here to avoid
# log-ingestion cost and listed in README "Known limitations".
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  # Don't hand out public IPs by default; only resources that ask for one (the Fargate task via
  # assign_public_ip, the internet-facing ALB) get one.
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project}-public-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Lock down the VPC's default security group: no rules means nothing can use it by accident.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

# ---------- Security groups ----------
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Public HTTP to the ALB; ALB to tasks only"
  vpc_id      = aws_vpc.main.id
}

# The ALB is the public entry point, so it must accept traffic from the internet.
# HTTP only: there's no domain/ACM certificate in this demo (README "Known limitations").
# Allowed by policies/no_public_ingress_non_web.rego (SMI-0001), which permits public ingress
# only on 80/443.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to tasks on the container port only"
  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

resource "aws_security_group" "task" {
  name        = "${var.project}-task"
  description = "Inbound only from the ALB; outbound HTTPS for ECR, Secrets Manager, CloudWatch"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id            = aws_security_group.task.id
  description                  = "App port from the ALB security group only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

# Tasks must reach ECR, Secrets Manager, and CloudWatch Logs public endpoints over HTTPS. Without
# a NAT gateway or VPC endpoints there's no fixed IP range for those, so egress is 0.0.0.0/0,
# restricted to TCP 443. Upgrade path: VPC endpoints + a prefix-list-scoped rule.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "task_https_out" {
  security_group_id = aws_security_group.task.id
  description       = "HTTPS to AWS service endpoints"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
