variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "uptime_check_url" {
  description = "URL to monitor"
  type        = string
  default     = "https://jordandesigns.io"
}

variable "uptime_alert_email" {
  description = "Email address for downtime alerts"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "Website Uptime Monitor"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}