# Container logs. The app writes one JSON object per line, so fields are queryable directly.
# Encryption: CloudWatch Logs encrypts at rest by default. A customer-managed key (Trivy AWS-0017,
# LOW) costs $1/month.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project}"
  retention_in_days = var.log_retention_days
}

# Turns the app's per-request `latency_ms` log field into a metric, so the dashboard can show
# server-side p50/p95/p99 for /predict next to the ALB's own latency.
resource "aws_cloudwatch_log_metric_filter" "predict_latency" {
  name           = "${var.project}-predict-latency"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.event = \"request\" && $.path = \"/predict\" && $.status = 200 }"

  metric_transformation {
    namespace = var.project
    name      = "PredictLatency"
    value     = "$.latency_ms"
    unit      = "Milliseconds"
  }
}
