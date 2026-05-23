# =============================================================================
# Website Uptime Monitor
# Health check for jordandesigns.io every 5 minutes
# EventBridge -> Lambda -> DynamoDB (log) + CloudWatch (metrics/dashboard) + SNS (alerts)
# =============================================================================

# --- DynamoDB Table ----------------------------------------------------------

resource "aws_dynamodb_table" "uptime_logs" {
  name         = "uptime-monitor-logs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "check_id"
  range_key    = "timestamp"

  attribute {
    name = "check_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = var.tags
}

# --- SNS Topic + Subscriptions -----------------------------------------------

resource "aws_sns_topic" "uptime_alerts" {
  name = "uptime-monitor-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "uptime_email" {
  topic_arn = aws_sns_topic.uptime_alerts.arn
  protocol  = "email"
  endpoint  = var.uptime_alert_email
}

resource "aws_sns_topic_subscription" "uptime_sms" {
  count     = var.uptime_alert_phone != "" ? 1 : 0
  topic_arn = aws_sns_topic.uptime_alerts.arn
  protocol  = "sms"
  endpoint  = var.uptime_alert_phone
}

# --- IAM Role for Lambda -----------------------------------------------------

resource "aws_iam_role" "uptime_lambda_role" {
  name = "uptime-monitor-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "uptime_lambda_policy" {
  name = "uptime-monitor-lambda-policy"
  role = aws_iam_role.uptime_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.uptime_logs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.uptime_alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --- Lambda Function ---------------------------------------------------------

resource "aws_lambda_function" "uptime_checker" {
  function_name = "uptime-monitor-checker"
  runtime       = "python3.13"
  handler       = "uptime_checker.lambda_handler"
  role          = aws_iam_role.uptime_lambda_role.arn
  filename      = "${path.module}/../../backend/uptime_checker.zip"
  timeout       = 30
  memory_size   = 128

  environment {
    variables = {
      CHECK_URL     = var.uptime_check_url
      TABLE_NAME    = aws_dynamodb_table.uptime_logs.name
      SNS_TOPIC     = aws_sns_topic.uptime_alerts.arn
      CONTENT_CHECK = var.uptime_content_check
      SSL_WARN_DAYS = "30"
      SSL_ALERT_DAYS = "7"
    }
  }

  tags = var.tags
}

# --- EventBridge Rule (every 5 minutes) --------------------------------------

resource "aws_cloudwatch_event_rule" "uptime_schedule" {
  name                = "uptime-monitor-5min"
  description         = "Triggers uptime check for jordandesigns.io every 5 minutes"
  schedule_expression = "rate(5 minutes)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "uptime_lambda_target" {
  rule      = aws_cloudwatch_event_rule.uptime_schedule.name
  target_id = "uptime-monitor-checker"
  arn       = aws_lambda_function.uptime_checker.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.uptime_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.uptime_schedule.arn
}

# --- CloudWatch Alarms -------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "site_down" {
  alarm_name          = "uptime-monitor-site-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "IsHealthy"
  namespace           = "UptimeMonitor"
  period              = 300
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "jordandesigns.io failed 2 consecutive checks"
  alarm_actions       = [aws_sns_topic.uptime_alerts.arn]
  ok_actions          = [aws_sns_topic.uptime_alerts.arn]

  dimensions = {
    URL = var.uptime_check_url
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "uptime-monitor-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "LatencyMs"
  namespace           = "UptimeMonitor"
  period              = 300
  statistic           = "Average"
  threshold           = 3000
  alarm_description   = "jordandesigns.io p-avg latency exceeded 3s for 3 consecutive checks"
  alarm_actions       = [aws_sns_topic.uptime_alerts.arn]

  dimensions = {
    URL = var.uptime_check_url
  }

  tags = var.tags
}

# --- CloudWatch Dashboard ----------------------------------------------------

resource "aws_cloudwatch_dashboard" "uptime" {
  dashboard_name = "uptime-monitor"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Site Health (1 = up, 0 = down)"
          view    = "timeSeries"
          stat    = "Minimum"
          period  = 300
          region  = var.aws_region
          metrics = [[
            "UptimeMonitor", "IsHealthy",
            "URL", var.uptime_check_url
          ]]
          yAxis       = { left = { min = 0, max = 1 } }
          annotations = { horizontal = [] }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title       = "Response Latency (ms)"
          view        = "timeSeries"
          stat        = "Average"
          period      = 300
          region      = var.aws_region
          metrics     = [[
            "UptimeMonitor", "LatencyMs",
            "URL", var.uptime_check_url
          ]]
          annotations = { horizontal = [] }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "SSL Days Remaining"
          view    = "timeSeries"
          stat    = "Minimum"
          period  = 3600
          region  = var.aws_region
          metrics = [[
            "UptimeMonitor", "SSLDaysRemaining",
            "URL", var.uptime_check_url
          ]]
          annotations = {
            horizontal = [
              { value = 30, label = "Warn threshold", color = "#f89256" },
              { value = 7, label = "Critical threshold", color = "#d62728" }
            ]
          }
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Active Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.site_down.arn,
            aws_cloudwatch_metric_alarm.high_latency.arn,
          ]
        }
      }
    ]
  })
}

# --- Outputs -----------------------------------------------------------------

output "uptime_table_name" {
  value = aws_dynamodb_table.uptime_logs.name
}

output "uptime_sns_topic_arn" {
  value = aws_sns_topic.uptime_alerts.arn
}

output "uptime_lambda_function_name" {
  value = aws_lambda_function.uptime_checker.function_name
}

output "uptime_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.uptime.dashboard_name}"
}
