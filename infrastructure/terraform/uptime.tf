# =============================================================================
# Website Uptime Monitor
# Weekly health check for jordandesigns.io
# EventBridge -> Lambda -> DynamoDB (log) + SNS (alert on failure)
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

# --- SNS Topic + Subscription ------------------------------------------------

resource "aws_sns_topic" "uptime_alerts" {
  name = "uptime-monitor-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "uptime_email" {
  topic_arn = aws_sns_topic.uptime_alerts.arn
  protocol  = "email"
  endpoint  = var.uptime_alert_email
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
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.uptime_logs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.uptime_alerts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --- Lambda Function ---------------------------------------------------------

resource "aws_lambda_function" "uptime_checker" {
  function_name = "uptime-monitor-checker"
  runtime       = "python3.11"
  handler       = "uptime_checker.lambda_handler"
  role          = aws_iam_role.uptime_lambda_role.arn
  filename      = "${path.module}/../../backend/uptime_checker.zip"
  timeout       = 30
  memory_size   = 128

  environment {
    variables = {
      CHECK_URL  = var.uptime_check_url
      TABLE_NAME = aws_dynamodb_table.uptime_logs.name
      SNS_TOPIC  = aws_sns_topic.uptime_alerts.arn
    }
  }

  tags = var.tags
}

# --- EventBridge Rule (Weekly: Sunday 9 AM CT / 14:00 UTC) -------------------

resource "aws_cloudwatch_event_rule" "uptime_schedule" {
  name                = "uptime-monitor-weekly"
  description         = "Triggers uptime check for jordandesigns.io every Sunday at 9 AM CT"
  schedule_expression = "cron(0 14 ? * SUN *)"
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