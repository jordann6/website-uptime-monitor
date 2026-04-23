# Website Uptime Monitor

Serverless uptime monitoring for [jordandesigns.io](https://jordandesigns.io) using AWS EventBridge, Lambda, DynamoDB, and SNS.

## Architecture

EventBridge triggers a Lambda function on a weekly schedule (Sunday 9 AM CT). The function performs an HTTP health check against the target URL, logs the result (status code, latency, timestamp) to DynamoDB, and publishes an SNS alert if the site is unreachable or returns a non 2xx/3xx response. DynamoDB TTL automatically expires log entries after 90 days.

## Resources

- **EventBridge Rule**: Weekly cron schedule (`cron(0 14 ? * SUN *)`)
- **Lambda Function**: Python 3.11, stdlib only (no external dependencies)
- **DynamoDB Table**: Composite key (`check_id` + `timestamp`), PAY_PER_REQUEST billing, 90 day TTL
- **SNS Topic**: Email subscription for downtime alerts
- **IAM Role**: Least privilege (DynamoDB PutItem/Query, SNS Publish, CloudWatch Logs)

## Deployment

```bash