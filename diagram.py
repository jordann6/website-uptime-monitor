from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import Lambda
from diagrams.aws.database import Dynamodb
from diagrams.aws.integration import EventbridgeScheduler, SimpleNotificationServiceSnsTopic, SimpleNotificationServiceSnsEmailNotification
from diagrams.aws.management import Cloudwatch, CloudwatchAlarm, CloudwatchLogs

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "ortho",
}

with Diagram(
    "Website Uptime Monitor",
    filename="docs/architecture",
    outformat="png",
    graph_attr=graph_attr,
    show=False,
):
    schedule = EventbridgeScheduler("EventBridge\nrate(5 min)")

    with Cluster("Lambda Function\nuptime-monitor-checker"):
        fn = Lambda("HTTP Check\nSSL Check\nContent Check\n+ 1 retry")

    logs = CloudwatchLogs("CloudWatch Logs")
    table = Dynamodb("DynamoDB\nuptime-monitor-logs\n90-day TTL")

    with Cluster("CloudWatch"):
        metrics = Cloudwatch("Custom Metrics\nIsHealthy\nLatencyMs\nSSLDaysRemaining")
        alarm_down = CloudwatchAlarm("site-down alarm\n2 failed checks")
        alarm_latency = CloudwatchAlarm("high-latency alarm\navg > 3s × 3")

    topic = SimpleNotificationServiceSnsTopic("SNS Topic\nuptime-monitor-alerts")
    email = SimpleNotificationServiceSnsEmailNotification("Email\njordandn6@outlook.com")
    sms = SimpleNotificationServiceSnsEmailNotification("SMS\n(optional)")

    schedule >> fn
    fn >> Edge(label="log result") >> table
    fn >> Edge(label="emit metrics") >> metrics
    fn >> Edge(label="structured logs") >> logs
    fn >> Edge(label="alert on failure", style="dashed", color="red") >> topic
    metrics >> alarm_down >> topic
    metrics >> alarm_latency >> topic
    topic >> email
    topic >> sms
