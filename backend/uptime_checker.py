import json
import os
import ssl
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta

import boto3

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
cloudwatch = boto3.client("cloudwatch")

TABLE_NAME = os.environ["TABLE_NAME"]
CHECK_URL = os.environ["CHECK_URL"]
SNS_TOPIC = os.environ["SNS_TOPIC"]
CONTENT_CHECK = os.environ.get("CONTENT_CHECK", "")  # substring to verify in response body
SSL_WARN_DAYS = int(os.environ.get("SSL_WARN_DAYS", "30"))
SSL_ALERT_DAYS = int(os.environ.get("SSL_ALERT_DAYS", "7"))

TTL_DAYS = 90
MAX_RETRIES = 1


def _http_check(url):
    """Returns (status_code, latency_ms, is_healthy, content_ok, error_message)."""
    start = time.monotonic()
    try:
        req = urllib.request.Request(url, method="GET")
        req.add_header("User-Agent", "UptimeMonitor/1.0")
        with urllib.request.urlopen(req, timeout=10) as response:
            status_code = response.getcode()
            body = response.read(8192).decode("utf-8", errors="ignore")
            latency_ms = round((time.monotonic() - start) * 1000)
            status_ok = 200 <= status_code < 400
            content_ok = (CONTENT_CHECK.lower() in body.lower()) if CONTENT_CHECK else True
            return status_code, latency_ms, status_ok and content_ok, content_ok, None
    except urllib.error.HTTPError as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        return e.code, latency_ms, False, False, str(e.reason)
    except urllib.error.URLError as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        return None, latency_ms, False, False, str(e.reason)
    except Exception as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        return None, latency_ms, False, False, str(e)


def _ssl_days_remaining(hostname):
    """Returns days until SSL cert expires, or None on error."""
    try:
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(
            __import__("socket").create_connection((hostname, 443), timeout=10),
            server_hostname=hostname,
        ) as sock:
            cert = sock.getpeercert()
            expiry = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
            return (expiry - datetime.now(timezone.utc)).days
    except Exception:
        return None


def _put_metric(metric_name, value, unit="None"):
    try:
        cloudwatch.put_metric_data(
            Namespace="UptimeMonitor",
            MetricData=[{
                "MetricName": metric_name,
                "Value": value,
                "Unit": unit,
                "Dimensions": [{"Name": "URL", "Value": CHECK_URL}],
            }],
        )
    except Exception:
        pass


def lambda_handler(event, context):
    table = dynamodb.Table(TABLE_NAME)
    now = datetime.now(timezone.utc)
    timestamp = now.isoformat()

    # Derive a stable check_id from the URL (strip scheme/trailing slash)
    check_id = CHECK_URL.replace("https://", "").replace("http://", "").rstrip("/")

    # HTTP check with one retry on failure
    status_code, latency_ms, is_healthy, content_ok, error_message = _http_check(CHECK_URL)
    if not is_healthy:
        time.sleep(5)
        status_code, latency_ms, is_healthy, content_ok, error_message = _http_check(CHECK_URL)

    # SSL check
    hostname = check_id.split("/")[0]
    ssl_days = _ssl_days_remaining(hostname) if CHECK_URL.startswith("https://") else None

    # Emit CloudWatch metrics
    _put_metric("IsHealthy", 1 if is_healthy else 0)
    _put_metric("LatencyMs", latency_ms, "Milliseconds")
    if ssl_days is not None:
        _put_metric("SSLDaysRemaining", ssl_days)

    # Build DynamoDB item
    ttl_value = int((now + timedelta(days=TTL_DAYS)).timestamp())
    item = {
        "check_id": check_id,
        "timestamp": timestamp,
        "status_code": status_code if status_code else 0,
        "latency_ms": latency_ms,
        "is_healthy": is_healthy,
        "content_ok": content_ok,
        "ssl_days_remaining": ssl_days,
        "ttl": ttl_value,
    }
    if error_message:
        item["error"] = error_message

    table.put_item(Item=item)
    print(json.dumps(item, default=str))

    # Alert on site down
    if not is_healthy:
        reason = []
        if status_code and not (200 <= status_code < 400):
            reason.append(f"HTTP {status_code}")
        if not content_ok and CONTENT_CHECK:
            reason.append("content check failed")
        if error_message:
            reason.append(error_message)

        subject = f"[DOWN] {check_id} — {', '.join(reason) or 'Unreachable'}"
        message = (
            f"Uptime check failed for {CHECK_URL}\n\n"
            f"Time:        {timestamp}\n"
            f"Status Code: {status_code or 'N/A'}\n"
            f"Latency:     {latency_ms} ms\n"
            f"Content OK:  {content_ok}\n"
            f"Error:       {error_message or 'None'}\n"
        )
        sns.publish(TopicArn=SNS_TOPIC, Subject=subject[:100], Message=message)
        print(f"Alert sent: {subject}")

    # Alert on SSL cert nearing expiry
    if ssl_days is not None:
        if ssl_days <= SSL_ALERT_DAYS:
            sns.publish(
                TopicArn=SNS_TOPIC,
                Subject=f"[SSL CRITICAL] {check_id} cert expires in {ssl_days} days",
                Message=f"SSL certificate for {hostname} expires in {ssl_days} days. Renew immediately.",
            )
        elif ssl_days <= SSL_WARN_DAYS:
            sns.publish(
                TopicArn=SNS_TOPIC,
                Subject=f"[SSL WARNING] {check_id} cert expires in {ssl_days} days",
                Message=f"SSL certificate for {hostname} expires in {ssl_days} days.",
            )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "checked": CHECK_URL,
            "healthy": is_healthy,
            "status_code": status_code,
            "latency_ms": latency_ms,
            "content_ok": content_ok,
            "ssl_days_remaining": ssl_days,
        }),
    }
