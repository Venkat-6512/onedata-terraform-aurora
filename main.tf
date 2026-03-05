terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Backend config passed via -backend-config flags in GitHub Actions
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

# ================================================================
# VPC
# ================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# ----------------------------------------------------------------
# Public Subnets
# ----------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public-${var.availability_zones[count.index]}"
    Project = var.project_name
    Tier    = "public"
  }
}

# ----------------------------------------------------------------
# Isolated Subnets — Aurora + Lambda (no internet route)
# ----------------------------------------------------------------
resource "aws_subnet" "isolated" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20)
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name    = "${var.project_name}-isolated-${var.availability_zones[count.index]}"
    Project = var.project_name
    Tier    = "isolated"
  }
}

# ----------------------------------------------------------------
# Internet Gateway + Route Tables
# ----------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-isolated-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "isolated" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

# ================================================================
# Security Groups
# ================================================================

# VPC Endpoint SG — allows HTTPS from within VPC
resource "aws_security_group" "vpc_endpoint" {
  name        = "${var.project_name}-vpce-sg"
  description = "Allow HTTPS from VPC to Secrets Manager endpoint"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-vpce-sg"
    Project = var.project_name
  }
}

# Lambda SG
resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda-sg"
  description = "Security group for Aurora connector Lambda"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-lambda-sg"
    Project = var.project_name
  }
}

# Rotation Lambda SG
resource "aws_security_group" "rotation_lambda" {
  name        = "${var.project_name}-rotation-lambda-sg"
  description = "Security group for Secrets Manager rotation Lambda"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-rotation-lambda-sg"
    Project = var.project_name
  }
}

# Aurora SG — only accepts traffic from Lambda SGs
resource "aws_security_group" "aurora" {
  name        = "${var.project_name}-aurora-sg"
  description = "Allow PostgreSQL only from Lambda and rotation Lambda"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id, aws_security_group.rotation_lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-aurora-sg"
    Project = var.project_name
  }
}

# ================================================================
# VPC Endpoint — Secrets Manager (Interface)
# Lambda in isolated subnets reaches Secrets Manager without NAT
# ================================================================
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.isolated[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name    = "${var.project_name}-secretsmanager-vpce"
    Project = var.project_name
  }
}

# ================================================================
# Secrets Manager
# ================================================================
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}/aurora/master-password"
  description             = "Master password for Aurora PostgreSQL cluster"
  recovery_window_in_days = 0

  tags = {
    Name    = "${var.project_name}-aurora-secret"
    Project = var.project_name
  }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    engine   = "aurora-postgresql"
    port     = 5432
    dbname   = var.db_name
  })
}

# ================================================================
# Aurora PostgreSQL Serverless v2
# ================================================================
resource "aws_db_subnet_group" "aurora" {
  name        = "${var.project_name}-aurora-subnet-group"
  description = "Subnet group for Aurora in isolated subnets"
  subnet_ids  = aws_subnet.isolated[*].id

  tags = {
    Name    = "${var.project_name}-aurora-subnet-group"
    Project = var.project_name
  }
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier     = "${var.project_name}-aurora-cluster"
  engine                 = "aurora-postgresql"
  engine_mode            = "serverless"
  engine_version         = "13.12"
  database_name          = var.db_name
  master_username        = var.db_username
  master_password        = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  scaling_configuration {
    auto_pause               = true
    min_capacity             = 2
    max_capacity             = 4
    seconds_until_auto_pause = 300
  }

  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 1
  storage_encrypted       = true
  enable_http_endpoint    = true

  depends_on = [aws_secretsmanager_secret_version.db_password]

  tags = {
    Name    = "${var.project_name}-aurora-cluster"
    Project = var.project_name
  }
}
# Note: Aurora Serverless v1 manages compute automatically - no aws_rds_cluster_instance needed

# ================================================================
# IAM — Lambda Role (GetSecretValue scoped to specific ARN only)
# ================================================================
resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name    = "${var.project_name}-lambda-role"
    Project = var.project_name
  }
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetSpecificSecretOnly"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Scoped to specific secret ARN — NO wildcard resources
        Resource = aws_secretsmanager_secret.db_password.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "VPCNetworkAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces"
        ]
        Resource = "*"
      }
    ]
  })
}

# ================================================================
# IAM — Rotation Lambda Role
# ================================================================
resource "aws_iam_role" "rotation_lambda" {
  name = "${var.project_name}-rotation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy" "rotation_lambda" {
  name = "${var.project_name}-rotation-lambda-policy"
  role = aws_iam_role.rotation_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRotation"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage"
        ]
        Resource = aws_secretsmanager_secret.db_password.arn
      },
      {
        Sid      = "VPCAccess"
        Effect   = "Allow"
        Action   = ["ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface", "ec2:DescribeNetworkInterfaces"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ================================================================
# CloudWatch Log Group
# ================================================================
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-aurora-connector"
  retention_in_days = 7

  tags = {
    Name    = "${var.project_name}-lambda-logs"
    Project = var.project_name
  }
}

# ================================================================
# Lambda — Aurora Connector (Python 3.12)
# ================================================================
data "archive_file" "lambda" {
  type        = "zip"
  output_path = "/tmp/aurora_connector.zip"
  source {
    content  = file("${path.module}/lambda/aurora_connector.py")
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "aurora_connector" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "${var.project_name}-aurora-connector"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30

  vpc_config {
    subnet_ids         = aws_subnet.isolated[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SECRET_ARN      = aws_secretsmanager_secret.db_password.arn
      DB_HOST         = aws_rds_cluster.aurora.endpoint
      DB_NAME         = var.db_name
      AWS_REGION_NAME = var.aws_region
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_rds_cluster.aurora
  ]

  tags = {
    Name    = "${var.project_name}-aurora-connector"
    Project = var.project_name
  }
}

# ================================================================
# Lambda — Secret Rotation Function
# ================================================================
data "archive_file" "rotation_lambda" {
  type        = "zip"
  output_path = "/tmp/rotation_lambda.zip"
  source {
    content  = file("${path.module}/lambda/rotation_function.py")
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "rotation" {
  filename         = data.archive_file.rotation_lambda.output_path
  function_name    = "${var.project_name}-secret-rotation"
  role             = aws_iam_role.rotation_lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.rotation_lambda.output_base64sha256
  timeout          = 30

  vpc_config {
    subnet_ids         = aws_subnet.isolated[*].id
    security_group_ids = [aws_security_group.rotation_lambda.id]
  }

  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${var.aws_region}.amazonaws.com"
    }
  }

  tags = { Project = var.project_name }
}

resource "aws_lambda_permission" "secretsmanager" {
  statement_id  = "AllowSecretsManagerInvocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.db_password.arn
}

# ================================================================
# Secrets Manager Rotation — 30 day schedule
# ================================================================
resource "aws_secretsmanager_secret_rotation" "db_password" {
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    automatically_after_days = var.rotation_days
  }

  depends_on = [aws_lambda_permission.secretsmanager]
}
