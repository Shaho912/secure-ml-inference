# CloudWatch dashboard (3 dashboards free). All metrics are free AWS-vended metrics except
# PredictLatency, which comes from the log metric filter in logs.tf.
locals {
  alb_dim = aws_lb.app.arn_suffix
  tg_dim  = aws_lb_target_group.app.arn_suffix
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "ALB latency (request in -> response out), seconds"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_dim, { stat = "p50", label = "p50" }],
            ["...", { stat = "p95", label = "p95" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "App-measured /predict latency (from logs), ms"
          region = var.region
          view   = "timeSeries"
          period = 60
          metrics = [
            [var.project, "PredictLatency", { stat = "p50", label = "p50" }],
            ["...", { stat = "p95", label = "p95" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 8, height = 6
        properties = {
          title  = "Requests and errors (count/min)"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_dim, { label = "requests" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { label = "app 5xx" }],
            [".", "HTTPCode_ELB_5XX_Count", ".", ".", { label = "ALB 5xx" }],
            [".", "HTTPCode_Target_4XX_Count", ".", ".", { label = "4xx (e.g. bad key)" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 6, width = 8, height = 6
        properties = {
          title  = "Healthy targets"
          region = var.region
          view   = "timeSeries"
          stat   = "Minimum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", local.tg_dim, "LoadBalancer", local.alb_dim],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 6, width = 8, height = 6
        properties = {
          title  = "ECS service CPU / memory, %"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name],
            [".", "MemoryUtilization", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Logs Insights: /predict latency percentiles per 5 min"
          region = var.region
          view   = "table"
          query  = <<-EOT
            SOURCE '${aws_cloudwatch_log_group.app.name}'
            | filter event = "request" and path = "/predict"
            | stats count(*) as requests, pct(latency_ms, 50) as p50_ms, pct(latency_ms, 95) as p95_ms, pct(latency_ms, 99) as p99_ms by bin(5m)
            | sort @timestamp desc
          EOT
        }
      },
    ]
  })
}
