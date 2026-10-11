# Internet-facing Application Load Balancer: a stable URL, health checks, and free latency metrics.
# It's public by design (Trivy AWS-0053). HTTP only (AWS-0054): no domain/ACM certificate in this
# demo. See README "Known limitations" for the HTTPS upgrade path.
#trivy:ignore:AWS-0053
resource "aws_lb" "app" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true # reject malformed headers (request-smuggling defense)
  idle_timeout               = 30
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip" # required for Fargate (awsvpc networking)
  vpc_id      = aws_vpc.main.id

  # Drain old tasks quickly during deploys (default 300s would add ~5 minutes to every deploy).
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

#trivy:ignore:AWS-0054
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
