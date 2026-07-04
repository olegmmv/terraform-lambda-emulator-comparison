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
# to localhost:4566, where MiniStack listens (it is LocalStack-endpoint
# compatible, so tflocal works unchanged). You never edit this file for local
# vs prod switching.
provider "aws" {
  region = "us-east-1"

  # Dummy creds for MiniStack (any values work). Replace with your credential
  # chain for real AWS.
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

# Zip is always built from dist/. Both stages deploy the same way — from a zip.
# MiniStack runs Node.js Lambdas in warm worker pools inside its own process
# (no per-function container, no bind-mount), so there is no hot-reload magic
# bucket to switch to for local. tflocal only rewrites the AWS endpoints to
# MiniStack; the Terraform config itself is identical for local and prod.
data "archive_file" "lambda_zip" {
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

# Deployed from the zip on both MiniStack (local) and real AWS (prod). To pick
# up a code change, rebuild the zip and re-apply — Terraform sees the new
# source_code_hash and calls UpdateFunctionCode. There is no hot-reload.
resource "aws_lambda_function" "hello" {
  function_name = "hello"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "hello.handler"
  runtime       = "nodejs20.x"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

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
