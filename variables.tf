variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as prefix for all resources"
  type        = string
  default     = "onedata-task4"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "db_username" {
  description = "Master username for Aurora PostgreSQL"
  type        = string
  default     = "dbadmin"
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "appdb"
}

variable "rotation_days" {
  description = "Number of days between secret rotations"
  type        = number
  default     = 30
}

variable "psycopg2_layer_arn" {
  description = "ARN of the psycopg2 Lambda layer (published via GitHub Actions before terraform apply)"
  type        = string
  default     = ""
}
