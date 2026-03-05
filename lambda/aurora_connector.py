"""
RDS PostgreSQL connector Lambda.
psycopg2 is bundled directly into the Lambda zip (lambda_bundle/).
Credentials retrieved from Secrets Manager at runtime — never hardcoded.
Connects via TCP within the VPC to the RDS instance.
Logs SUCCESS to CloudWatch. Password is never logged.
"""

import json
import logging
import os
import boto3
import psycopg2

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    secret_arn = os.environ["SECRET_ARN"]
    db_host    = os.environ["DB_HOST"]
    db_name    = os.environ["DB_NAME"]
    region     = os.environ.get("AWS_REGION_NAME", "us-east-1")

    logger.info("Fetching DB credentials from Secrets Manager")

    # Retrieve secret — no hardcoded credentials
    sm = boto3.client("secretsmanager", region_name=region)
    try:
        secret = json.loads(sm.get_secret_value(SecretId=secret_arn)["SecretString"])
    except Exception as e:
        logger.error(f"Failed to retrieve secret: {e}")
        raise

    logger.info(f"Credentials retrieved for user: {secret['username']}")
    logger.info(f"Connecting to: {db_host}/{db_name}")

    # Connect to RDS PostgreSQL — password never logged
    conn = None
    try:
        conn = psycopg2.connect(
            host=db_host,
            port=5432,
            database=db_name,
            user=secret["username"],
            password=secret["password"],
            connect_timeout=10,
            sslmode="require",
        )
        with conn.cursor() as cur:
            cur.execute("SELECT version(), current_database(), current_user, NOW()")
            row = cur.fetchone()

        logger.info("=" * 60)
        logger.info("SUCCESS: Connected to RDS PostgreSQL")
        logger.info(f"Version  : {row[0]}")
        logger.info(f"Database : {row[1]}")
        logger.info(f"User     : {row[2]}")
        logger.info(f"Time     : {row[3]}")
        logger.info("=" * 60)

        return {
            "statusCode": 200,
            "body": json.dumps({
                "status": "SUCCESS",
                "message": "Successfully connected to RDS PostgreSQL",
                "database": row[1],
                "user": row[2],
                "server_time": str(row[3]),
                "db_version": row[0].split(",")[0],
            })
        }

    except Exception as e:
        logger.error(f"FAILED: {e}")
        raise
    finally:
        if conn:
            conn.close()
            logger.info("Connection closed")
