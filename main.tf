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
variable "ENV_VARS" {
  description = "List environment of lambda functions"
}
variable "TAGS" {
  description = "List tags"
}

# Get the custom policies database
data "http" "custom_policy" {
  url = "https://raw.githubusercontent.com/TravelOffice/terraform-policy-database/master/custom_policy.json"
}
locals {
  lambda_default_config = {
    handler       = "lambda.handler"
    memory_size   = 128
    runtime       = "nodejs14.x"
    timeout       = 3
    architecture  = "arm64"
    log_retention = 30
    permission = {
      custom_policies = ["LambdaStandardRole"]
      aws_policies    = []
    },
    env_vars = "standard_vars"
  }
  root_path = format("%s/../../..", path.root)
  lambda_functions_roles = {
    for key, value in var.LAMBDA_FUNCTIONS : key => {
      path          = value.path
      handler       = "lambda.handler"
      memory_size   = try(value.memory_size, local.lambda_default_config.memory_size)
      runtime       = try(value.runtime, local.lambda_default_config.runtime)
      timeout       = try(value.timeout, local.lambda_default_config.timeout)
      architecture  = try(value.architecture, local.lambda_default_config.architecture)
      log_retention = try(value.log_retention, local.lambda_default_config.log_retention)
      permission = {
        custom_policies = try(value.permission.custom_policies, local.lambda_default_config.permission.custom_policies)
        aws_policies    = try(value.permission.aws_policies, local.lambda_default_config.permission.aws_policies)
      },
      env_vars = try(value.env_vars, local.lambda_default_config.env_vars)
      layers   = value.layers
      custom_policies = flatten([
        for policy in value.permission.custom_policies : [
          jsondecode(data.http.custom_policy.body)[policy]
        ]
      ])
      aws_policies = flatten([
        for policy in value.permission.aws_policies : [
          format("%s/%s", "arn:aws:iam::aws:policy", policy)
        ]
      ])
    }
  }
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

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "policy" {
  for_each    = local.lambda_functions_roles
  name_prefix = lower("${var.ENV}-${var.FEATURE_NAME}-${each.key}")

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = "${each.value.custom_policies}"
  })

  tags = var.TAGS
}

resource "aws_iam_role" "role" {
  for_each            = local.lambda_functions_roles
  name                = lower("${var.ENV}-${var.FEATURE_NAME}-${each.key}")
  assume_role_policy  = data.aws_iam_policy_document.assume_role_policy.json
  managed_policy_arns = concat([aws_iam_policy.policy[each.key].arn], each.value.aws_policies)
  tags                = var.TAGS
}

resource "aws_lambda_function" "lambda" {
  for_each         = local.lambda_functions_roles
  filename         = format("%s/%s", local.root_path, "deploy/${each.key}.zip")
  function_name    = lower("${var.ENV}-${var.FEATURE_NAME}-${each.key}")
  role             = aws_iam_role.role[each.key].arn
  memory_size      = each.value.memory_size
  handler          = each.value.handler
  source_code_hash = filebase64sha256(format("%s/%s", local.root_path, "deploy/${each.key}.zip"))
  architectures    = [each.value.architecture]
  runtime          = each.value.runtime
  timeout          = each.value.timeout
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
  tracing_config = {
    mode = "Active"
  }
  environment {
    variables = var.ENV_VARS[each.value.env_vars]
  }

  tags = var.TAGS

}

output "lambda_arns" {
  value = { for key, value in var.LAMBDA_FUNCTIONS : key => aws_lambda_function.lambda[key].arn }
}
