output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.aurora_connector.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.aurora_connector.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for Lambda"
  value       = aws_cloudwatch_log_group.lambda.name
}
