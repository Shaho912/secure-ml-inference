# ECS Fargate cluster + service.
# Container Insights is off (Trivy AWS-0034, LOW): it bills per custom metric. The free
# AWS/ECS CPUUtilization and MemoryUtilization metrics feed the dashboard instead.
resource "aws_ecs_cluster" "main" {
  name = var.project

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

locals {
  container_name = "app"
}

# Terraform registers the FIRST revision with a placeholder tag. CI then registers new revisions
# with the real :<git-sha> image. The service ignores task_definition changes (see lifecycle
# below), so Terraform and CI don't fight. If you change settings here, `apply` registers a new
# revision, and the next CI deploy picks it up (it renders the latest revision with the new image).
resource "aws_ecs_task_definition" "app" {
  family                   = var.project
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Writable scratch space for upload spooling, since the root filesystem is read-only.
  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([{
    name      = local.container_name
    image     = "${aws_ecr_repository.app.repository_url}:bootstrap" # replaced by CI on deploy
    essential = true
    user      = "10001:10001"

    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

    # Same hardening as the local `docker run --read-only --cap-drop ALL` test.
    readonlyRootFilesystem = true
    mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
    linuxParameters = {
      capabilities       = { drop = ["ALL"] }
      initProcessEnabled = true # tini as PID 1: forwards SIGTERM so uvicorn shuts down cleanly
    }

    environment = [
      { name = "LOG_LEVEL", value = "INFO" },
      { name = "TORCH_THREADS", value = "1" },
    ]
    # Injected by the ECS agent at task start; never stored in the task definition or image.
    secrets = [{ name = "API_KEY", valueFrom = aws_secretsmanager_secret.api_key.arn }]

    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health', timeout=4)"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60 # torch import + model load take several seconds on 0.5 vCPU
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = var.project
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"

  # 0 at creation: ECR is still empty, so a running task would crash-loop on the missing image.
  # The first CI deploy sets desired-count to 1. ignore_changes below keeps Terraform from
  # scaling it back to 0 on later applies.
  desired_count = 0

  deployment_minimum_healthy_percent = 100 # start the new task before stopping the old one
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 90

  deployment_circuit_breaker {
    enable   = true
    rollback = true # a deploy that never becomes healthy rolls back automatically
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # needed without a NAT gateway; inbound is still ALB-only
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  propagate_tags         = "SERVICE"
  enable_execute_command = false # no shell access into running tasks

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.execution]
}
