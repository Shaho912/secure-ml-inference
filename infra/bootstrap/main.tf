# Cost guardrails, applied BEFORE any billable infrastructure exists.
# Two independent alert paths, so a misconfiguration in one doesn't leave you blind:
#   1. CloudWatch alarm on EstimatedCharges -> SNS -> email
#   2. AWS Budget (actual + forecasted spend) -> email directly
# Cost: $0 (CloudWatch: 10 alarms free; Budgets: first 2 free; SNS: 1,000 emails/month free).

# SNS topic for the alarm.
# Not encrypted with SSE. The AWS-managed key (alias/aws/sns) has a key policy that CloudWatch
# can't use, so alarm notifications would be silently dropped. A customer-managed KMS key would
# work, but costs $1/month for a topic that only carries "your bill passed $X" messages.
#trivy:ignore:AVD-AWS-0095
resource "aws_sns_topic" "billing_alerts" {
  name = "${var.project}-billing-alerts"
}

# Allow only CloudWatch, and only for alarms in this account, to publish to the topic.
data "aws_caller_identity" "current" {}

resource "aws_sns_topic_policy" "billing_alerts" {
  arn = aws_sns_topic.billing_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.billing_alerts.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# You must click the confirmation link AWS emails you before alerts are delivered.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.billing_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Requires "Receive CloudWatch billing alerts" to be enabled once in the Billing console
# (Billing preferences). Until then the metric doesn't exist and the alarm stays INSUFFICIENT_DATA.
resource "aws_cloudwatch_metric_alarm" "estimated_charges" {
  alarm_name          = "${var.project}-estimated-charges-over-${var.monthly_limit_usd}usd"
  alarm_description   = "Estimated AWS charges this month exceeded $${var.monthly_limit_usd}."
  namespace           = "AWS/Billing"
  metric_name         = "EstimatedCharges"
  dimensions          = { Currency = "USD" }
  statistic           = "Maximum"
  period              = 21600 # billing metric updates roughly every 6 hours
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.monthly_limit_usd
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.billing_alerts.arn]
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alerts on actual spend at 50/80/100% of the limit...
  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }

  # ...plus an early warning when AWS forecasts the month will exceed the limit.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
