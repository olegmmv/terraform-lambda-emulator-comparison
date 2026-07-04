variable "stage" {
  type        = string
  default     = "local"
  description = <<-EOT
    Deployment stage. Same zip deploy either way — only the AWS endpoints differ.
    "local"  → deploy to MiniStack (endpoints redirected to localhost:4566 by tflocal).
    Anything else (e.g. "prod") → deploy to real AWS.
    Also drives the IAM role name and the STAGE env var passed to the function.
  EOT

  validation {
    condition     = length(var.stage) > 0
    error_message = "stage must not be empty."
  }
}
