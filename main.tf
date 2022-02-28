variable "SUBNETS" {
    description = "VPC subnets"
}

variable "VPC_ID" {
    description = "VPC id"
}
variable "LAMBDA_LAYER_ARNS" {
    description = "List lambda layer arns"
}
variable "LAMBDA_FUNCTIONS" {
    description = "List argument of lambda functions"
}
variable "ENV" {
    description = "Environment"
}
variable "FEATURE_NAME" {
    description = "Feature name"
}
variable "IAM_ROLES" {
    description = "List IAM roles for lambda functions"
}
variable "ENV_VARS" {
    description = "List environment of lambda functions"
}
variable "TAGS" {
    description = "List tags"
}
locals {
  lambda_default_config = {
    handler       = "lambda.handler"
    memory_size   = 128
    runtime       = "nodejs14.x"
    timeout       = 3
    architecture  = "arm64"
    log_retention = 30
    iam_role      = "standard_lambda_role"
    env_vars      = "standard_vars"
  }
  root_path = format("%s/../../..", path.root)
}
resource "aws_security_group" "lambda_sg" {
  name_prefix = "lambda_sg"
  description = "Allow all outbound traffic"
  vpc_id      = var.VPC_ID

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  tags = var.TAGS

}

data "archive_file" "lambda_zip" {
  for_each    = var.LAMBDA_FUNCTIONS
  type        = "zip"
  source_dir  = format("%s/%s", local.root_path, each.value.path)
  output_path = format("%s/%s", local.root_path, "deploy/${each.key}.zip")
}

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  for_each          = var.LAMBDA_FUNCTIONS
  name              = "/aws/lambda/${var.ENV}-${var.FEATURE_NAME}-${each.key}"
  retention_in_days = try(each.value.log_retention, local.lambda_default_config.log_retention)
  tags              = var.TAGS

}
resource "aws_lambda_function" "lambda" {
  for_each         = var.LAMBDA_FUNCTIONS
  filename         = format("%s/%s", local.root_path, "deploy/${each.key}.zip")
  function_name    = "${var.ENV}-${var.FEATURE_NAME}-${each.key}"
  role             = var.IAM_ROLES[try(each.value.iam_role, local.lambda_default_config.iam_role)]
  memory_size      = try(each.value.memory_size, local.lambda_default_config.memory_size)
  handler          = try(each.value.handler, local.lambda_default_config.handler)
  source_code_hash = filebase64sha256(format("%s/%s", local.root_path, "deploy/${each.key}.zip"))
  architectures    = [try(each.value.architecture, local.lambda_default_config.architecture)]
  runtime          = try(each.value.runtime, local.lambda_default_config.runtime)
  timeout          = try(each.value.timeout, local.lambda_default_config.timeout)
  depends_on = [
    aws_cloudwatch_log_group.lambda_log_group
  ]
  vpc_config {
    # Every subnet should be able to reach an EFS mount target in the same Availability Zone. Cross-AZ mounts are not permitted.
    subnet_ids         = var.SUBNETS
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
  layers = [
    for layer in each.value.layers : var.LAMBDA_LAYER_ARNS[layer]
  ]
  environment {
    variables = var.ENV_VARS[try(each.value.env_vars, local.lambda_default_config.env_vars)]
  }

  tags = var.TAGS

}

output "lambda_arns" {
  value = { for key, value in var.LAMBDA_FUNCTIONS : key => aws_lambda_function.lambda[key].arn }
}
