terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"

    }
  }
}




# --- REPLACE your current provider block with this ---
provider "aws" {
  region = "us-east-1"
  #access_key = "YOUR_NEW_ACCESS_KEY_ID"
  #secret_key = "YOUR_NEW_SECRET_ACCESS_KEY"

  # Point explicitly to the Windows paths so Terraform doesn't guess HOME
  #shared_credentials_files = ["C:/Users/rehan.tayyab/.aws/credentials"]  # <— change to your path
  #shared_config_files      = ["C:/Users/rehan.tayyab/.aws/config"]       # <— change to your path
}



# --- ZIP the Lambda code locally ---
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/handler.py"
  output_path = "${path.module}/handler.zip"
}

# --- Execution role for Lambda ---
resource "aws_iam_role" "lambda_exec" {
  name = "coventry-sim-lambda-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# --- Basic logging permissions ---
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- The Lambda function itself ---
resource "aws_lambda_function" "hello" {
  function_name    = "coventry-sim-hello"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.11"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256  
  layers = [aws_lambda_layer_version.pymongo.arn]    # Attach your custom PyMongo layer
  timeout = 15
}

# --- HTTP API ---
resource "aws_apigatewayv2_api" "http" {
  name          = "coventry-sim-http"
  protocol_type = "HTTP"

  # ✅ CORS so the web page can call the API
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST"]
    allow_headers = ["*"]
  }
}


# --- Integrate Lambda with API Gateway ---
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.hello.invoke_arn
  payload_format_version = "2.0"
}

# --- Route: GET /hello -> Lambda ---
resource "aws_apigatewayv2_route" "get_hello" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /hello"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


# POST /submit  → Lambda     ## added later to check API post function
resource "aws_apigatewayv2_route" "post_submit" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /submit"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}


# --- Stage (auto-deploy) ---
resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

# --- Allow API Gateway to invoke Lambda ---
resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

# --- Handy output: invoke URL ---
output "api_invoke_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}


# --- S3 static website bucket ---
resource "aws_s3_bucket" "site" {
  bucket = "coventry-sim-site-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {
  byte_length = 3
}

# Public access OFF switches so policy can work
resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}



# --- Allow public read access to objects ---
data "aws_iam_policy_document" "site_public_read" {
  statement {
    sid = "PublicReadObjects"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"] # ✅ target objects only
  }

  # (Optional) uncomment to allow listing the bucket in browsers
  # statement {
  #   sid = "AllowListBucket"
  #   principals {
  #     type        = "*"
  #     identifiers = ["*"]
  #   }
  #   actions   = ["s3:ListBucket"]
  #   resources = [aws_s3_bucket.site.arn]
  # }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_public_read.json
}





# Enable website hosting
resource "aws_s3_bucket_website_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  index_document {
    suffix = "index.html"
  }
}

output "site_url" {
  value = "http://${aws_s3_bucket_website_configuration.site.website_endpoint}"
}




############ mongodb part starting from here ########

# ---- SSM parameter to hold your MongoDB URI (secure) ----
resource "aws_ssm_parameter" "mongodb_uri" {
  name  = "/coventry-sim/MONGODB_URI"
  type  = "SecureString"
  value = "mongodb+srv://appuser:pakistan1947@cov-univ-simu.vql0xrl.mongodb.net/?appName=cov-univ-simu" # mongodb+srv://appuser:...@.../coventrydb?retryWrites=true&w=majority
  tags = {
    Project = "coventry-sim"
  }
}

# Allow Lambda to read the MongoDB URI from SSM
resource "aws_iam_role_policy" "lambda_ssm_access" {
  name = "lambda-ssm-access"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParameterHistory"
        ],
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/coventry-sim/*"
      }
    ]
  })
}

# Helper data blocks if not already present
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}



# Create an S3 bucket for Lambda layers
resource "aws_s3_bucket" "lambda_layer_bucket" {
  bucket = "coventry-sim-lambda-layers-${random_id.suffix.hex}"
}

# Create a Lambda layer from your uploaded ZIP
resource "aws_lambda_layer_version" "pymongo" {
  layer_name          = "pymongo-layer"
  compatible_runtimes = ["python3.11"]
  s3_bucket           = aws_s3_bucket.lambda_layer_bucket.id
  s3_key              = "pymongo-layer.zip"
  description         = "Custom pymongo layer for Lambda"
}






