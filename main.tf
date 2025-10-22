provider "aws" {
  region = "eu-central-1"
}

#S3 bucket setup
resource "aws_s3_bucket" "glue_scripts" {
  bucket_prefix = "glue-scripts-"
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.glue_scripts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Upload the Glue script from local folder to S3
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.glue_scripts.bucket
  key    = "scripts/my_glue_job.py"
  source = "${path.module}/glue/pyspark_job.py"
  etag   = filemd5("${path.module}/glue/pyspark_job.py")
}

#IAM role
resource "aws_iam_role" "glue_role" {
  name = "glue_service_role_example"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_basic" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy_attachment" "glue_s3_access" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

#glue job definition
resource "aws_glue_job" "example_job" {
  name     = "my-glue-job"
  role_arn = aws_iam_role.glue_role.arn

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.glue_scripts.bucket}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--TempDir"       = "s3://${aws_s3_bucket.glue_scripts.bucket}/tmp/"
    "--job-language"  = "python"
    "--my_flag"       = "true"
  }

  glue_version = "4.0"
  max_capacity = 2
  timeout      = 10
}

#glue trigger
resource "aws_glue_trigger" "every_5_minutes" {
  name     = "trigger-every-5-minutes"
  type     = "SCHEDULED"
  schedule = "rate(5 minutes)"

  actions {
    job_name  = aws_glue_job.example_job.name
    arguments = { "--my_flag" = "false" }
  }

  start_on_creation = true
}

#outputs
output "glue_job_name" {
  value = aws_glue_job.example_job.name
}

output "glue_trigger_name" {
  value = aws_glue_trigger.every_5_minutes.name
}

output "s3_bucket" {
  value = aws_s3_bucket.glue_scripts.bucket
}
