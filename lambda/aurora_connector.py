"""
RDS PostgreSQL connector Lambda.

Retrieves DB credentials from Secrets Manager at runtime (never hardcoded),
connects to the Aurora cluster, and logs a SUCCESS message to CloudWatch.
Password is never logged.
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
    logger.info(f"Secret ARN: {secret_arn}")

    # -------------------------------------------------------
    # Retrieve secret - no hardcoded credentials anywhere
    # -------------------------------------------------------
    sm_client = boto3.client("secretsmanager", region_name=region)
    try:
        response = sm_client.get_secret_value(SecretId=secret_arn)
        secret = json.loads(response["SecretString"])
    except Exception as e:
        logger.error(f"Failed to retrieve secret: {str(e)}")
        raise

    db_user = secret["username"]
    db_pass = secret["password"]
    # NOTE: password is intentionally never logged

    logger.info(f"Successfully retrieved credentials for user: {db_user}")
    logger.info(f"Attempting connection to Aurora at host: {db_host}, database: {db_name}")

    # -------------------------------------------------------
    # Connect to Aurora PostgreSQL
    # -------------------------------------------------------
    conn = None
    try:
        conn = psycopg2.connect(
            host=db_host,
            port=5432,
            database=db_name,
            user=db_user,
            password=db_pass,
            connect_timeout=10,
            sslmode="require",
        )

        with conn.cursor() as cur:
            cur.execute("SELECT version();")
            db_version = cur.fetchone()[0]

            cur.execute("SELECT current_database(), current_user, NOW();")
            db_info = cur.fetchone()

        logger.info("=" * 60)
        logger.info("SUCCESS: Connected to RDS PostgreSQL")
        logger.info(f"Database version: {db_version}")
        logger.info(f"Connected to database: {db_info[0]}")
        logger.info(f"Connected as user: {db_info[1]}")
        logger.info(f"Server time: {db_info[2]}")
        logger.info("=" * 60)

        return {
            "statusCode": 200,
            "body": json.dumps({
                "status": "SUCCESS",
                "message": "Successfully connected to RDS PostgreSQL",
                "database": db_info[0],
                "user": db_info[1],
                "server_time": str(db_info[2]),
                "db_version": db_version.split(",")[0],
            })
        }

    except psycopg2.OperationalError as e:
        logger.error(f"FAILED: Could not connect to RDS PostgreSQL: {str(e)}")
        raise
    except Exception as e:
        logger.error(f"Unexpected error: {str(e)}")
        raise
    finally:
        if conn:
            conn.close()
            logger.info("Database connection closed")
