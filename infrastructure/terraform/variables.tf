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

variable "uptime_alert_phone" {
  description = "E.164 phone number for SMS alerts (e.g. +15551234567). Leave empty to skip SMS."
  type        = string
  default     = ""
}

variable "uptime_content_check" {
  description = "Substring to verify exists in the response body. Empty string disables the check."
  type        = string
  default     = ""
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
