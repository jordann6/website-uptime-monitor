import json
import os
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta

import boto3

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")

TABLE_NAME = os.environ["TABLE_NAME"]
CHECK_URL = os.environ["CHECK_URL"]
SNS_TOPIC = os.environ["SNS_TOPIC"]

# TTL: keep logs for 90 days
TTL_DAYS = 90


def lambda_handler(event, context):
    table = dynamodb.Table(TABLE_NAME)
    now = datetime.now(timezone.utc)
    timestamp = now.isoformat()
    check_id = "jordandesigns.io"

    status_code = None
    latency_ms = None
    error_message = None
    is_healthy = False

    # Perform the health check
    start = time.monotonic()
    try:
        req = urllib.request.Request(CHECK_URL, method="GET")
        req.add_header("User-Agent", "UptimeMonitor/1.0")
        with urllib.request.urlopen(req, timeout=10) as response:
            status_code = response.getcode()
            latency_ms = round((time.monotonic() - start) * 1000)
            is_healthy = 200 <= status_code < 400
    except urllib.error.HTTPError as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        status_code = e.code
        error_message = str(e.reason)
        is_healthy = False
    except urllib.error.URLError as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        error_message = str(e.reason)
        is_healthy = False
    except Exception as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        error_message = str(e)
        is_healthy = False

    # Build the DynamoDB item
    ttl_value = int((now + timedelta(days=TTL_DAYS)).timestamp())
    item = {
        "check_id": check_id,
        "timestamp": timestamp,
        "status_code": status_code if status_code else 0,
        "latency_ms": latency_ms if latency_ms else 0,
        "is_healthy": is_healthy,
        "ttl": ttl_value,
    }
    if error_message:
        item["error"] = error_message

    # Log to DynamoDB
    table.put_item(Item=item)
    print(json.dumps(item, default=str))

    # Alert on failure
    if not is_healthy:
        subject = f"[DOWN] jordandesigns.io — {status_code or 'Unreachable'}"
        message = (
            f"Uptime check failed for {CHECK_URL}\n\n"
            f"Time: {timestamp}\n"
            f"Status Code: {status_code or 'N/A'}\n"
            f"Latency: {latency_ms} ms\n"
            f"Error: {error_message or 'None'}\n"
        )
        sns.publish(
            TopicArn=SNS_TOPIC,
            Subject=subject[:100],
            Message=message,
        )
        print(f"Alert sent: {subject}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "checked": CHECK_URL,
            "healthy": is_healthy,
            "status_code": status_code,
            "latency_ms": latency_ms,
        }),
    }