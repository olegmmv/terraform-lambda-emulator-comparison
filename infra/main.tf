terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# tflocal generates localstack_providers_override.tf to redirect all endpoints
# to localhost:4566, where Floci listens (Floci is API-compatible with the
# LocalStack endpoint, so tflocal works unchanged). You never edit this file
# for local vs prod switching.
provider "aws" {
  region = "us-east-1"

  # Dummy creds for Floci (any non-empty values work). Replace with your
  # credential chain for real AWS.
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

locals {
  is_local = var.stage == "local"
}

# Zip — only built for real AWS deploys (count = 0 when local)
data "archive_file" "lambda_zip" {
  count = local.is_local ? 0 : 1

  type        = "zip"
  source_dir  = "${path.module}/../dist"
  output_path = "${path.module}/.build/lambda.zip"
}

resource "aws_iam_role" "lambda_exec" {
  name = "hello-lambda-exec-${var.stage}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# When s3_bucket = "hot-reload", Floci bind-mounts s3_key (an absolute
# path on the HOST) into the Lambda container and reloads on the next invoke
# when files change. Requires FLOCI_SERVICES_LAMBDA_HOT_RELOAD_ENABLED=true
# (set in docker-compose.yml) — Floci ships this off by default.
# For real AWS, s3_bucket/s3_key are null and the zip is used instead.
resource "aws_lambda_function" "hello" {
  function_name = "hello"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "hello.handler"
  runtime       = "nodejs20.x"

  # Floci hot-reload
  s3_bucket = local.is_local ? "hot-reload" : null
  s3_key    = local.is_local ? var.lambda_mount_path : null

  # Real AWS
  filename         = local.is_local ? null : data.archive_file.lambda_zip[0].output_path
  source_code_hash = local.is_local ? null : data.archive_file.lambda_zip[0].output_base64sha256

  environment {
    variables = {
      STAGE = var.stage
    }
  }
}

resource "aws_cloudwatch_log_group" "hello_logs" {
  name              = "/aws/lambda/${aws_lambda_function.hello.function_name}"
  retention_in_days = 7
}
