output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "aurora_cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = module.aurora.cluster_endpoint
}

output "aurora_cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = module.aurora.cluster_reader_endpoint
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret"
  value       = module.secrets.secret_arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = module.lambda.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = module.lambda.function_arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for Lambda"
  value       = module.lambda.log_group_name
}
