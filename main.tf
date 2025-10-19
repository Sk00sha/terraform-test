terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.4.0"
}

provider "aws" {
  region = "us-east-1"
}

resource "random_id" "suffix" {
  byte_length = 4
}

# --- S3 bucket for Glue output ---
resource "aws_s3_bucket" "output" {
  bucket = "ai-book-app-sk00sha-${random_id.suffix.hex}"
}

# --- IAM Role for Glue ---
resource "aws_iam_role" "glue_role" {
  name = "glue_demo_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
  })
}

# Attach Glue service and S3 access
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_access" {
  name = "glue_s3_access_policy"
  role = aws_iam_role.glue_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:*"],
        Resource = [
          aws_s3_bucket.output.arn,
          "${aws_s3_bucket.output.arn}/*"
        ]
      }
    ]
  })
}

# --- Upload Glue script to S3 ---
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.output.id
  key    = "scripts/pyspark_job.py"
  source = "${path.module}/glue/pyspark_job.py"
}

# --- Glue Job ---
resource "aws_glue_job" "demo_glue_job" {
  name     = "demo_glue_job"
  role_arn = aws_iam_role.glue_role.arn

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.output.bucket}/${aws_s3_object.glue_script.key}"
  }

  default_arguments = {
    "--TempDir"     = "s3://${aws_s3_bucket.output.bucket}/temp/"
    "--output_path" = "s3://${aws_s3_bucket.output.bucket}/output/"
  }

  glue_version = "4.0"
  max_capacity = 2
}

# --- IAM Role for Lambda ---
resource "aws_iam_role" "lambda_role" {
  name = "lambda_glue_trigger_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_exec" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_glue_trigger_policy" {
  name   = "lambda_glue_trigger_policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["glue:StartJobRun"],
        Resource = aws_glue_job.demo_glue_job.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_glue_trigger_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_glue_trigger_policy.arn
}

# --- Package Lambda ---
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

# --- Lambda Function ---
resource "aws_lambda_function" "glue_trigger_lambda" {
  function_name = "trigger_glue_job_lambda"
  handler       = "handler.lambda_handler"
  runtime       = "python3.9"
  filename      = data.archive_file.lambda_zip.output_path
  role          = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      GLUE_JOB_NAME = aws_glue_job.demo_glue_job.name
    }
  }
}

# --- Scheduler (EventBridge Rule) ---
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  name                = "trigger-glue-job-schedule"
  description         = "Runs Glue job every hour"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.lambda_schedule.name
  target_id = "triggerLambda"
  arn       = aws_lambda_function.glue_trigger_lambda.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.glue_trigger_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule.arn
}
