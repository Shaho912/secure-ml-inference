output "billing_alerts_topic_arn" {
  value = aws_sns_topic.billing_alerts.arn
}

output "billing_alarm_name" {
  value = aws_cloudwatch_metric_alarm.estimated_charges.alarm_name
}

output "budget_name" {
  value = aws_budgets_budget.monthly.name
}
