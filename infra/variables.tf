variable "stage" {
  type        = string
  default     = "local"
  description = <<-EOT
    Deployment stage.
    "local"  → Floci hot-reload via magic "hot-reload" S3 bucket.
    Anything else (e.g. "prod") → real zip deploy to AWS.
  EOT

  validation {
    condition     = length(var.stage) > 0
    error_message = "stage must not be empty."
  }
}

variable "lambda_mount_path" {
  type        = string
  default     = ""
  description = <<-EOT
    Absolute path to the dist/ directory on the HOST machine.
    Required when stage = "local". Must match the volume mount in docker-compose.yml.
    Example: "/Users/you/project/dist"
  EOT
}
