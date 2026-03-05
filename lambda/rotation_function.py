"""
AWS Secrets Manager rotation Lambda for Aurora PostgreSQL.
Rotates the master password by generating a new one and updating both
the secret and the Aurora cluster.
"""

import boto3
import json
import logging
import os
import string
import random

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """Entry point for the rotation Lambda."""
    arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]

    service_client = boto3.client("secretsmanager")

    metadata = service_client.describe_secret(SecretId=arn)
    if not metadata["RotationEnabled"]:
        raise ValueError(f"Secret {arn} is not enabled for rotation")

    versions = metadata.get("VersionIdsToStages", {})
    if token not in versions:
        raise ValueError(f"Secret version {token} has no stage for secret {arn}")

    if "AWSCURRENT" in versions[token]:
        logger.info(f"Secret version {token} is already set as AWSCURRENT - no rotation needed")
        return
    elif "AWSPENDING" not in versions[token]:
        raise ValueError(f"Secret version {token} not set as AWSPENDING for secret {arn}")

    if step == "createSecret":
        create_secret(service_client, arn, token)
    elif step == "setSecret":
        set_secret(service_client, arn, token)
    elif step == "testSecret":
        test_secret(service_client, arn, token)
    elif step == "finishSecret":
        finish_secret(service_client, arn, token)
    else:
        raise ValueError(f"Invalid step parameter: {step}")


def create_secret(service_client, arn, token):
    """Create a new secret version with a new password."""
    try:
        service_client.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)
        logger.info(f"createSecret: AWSPENDING version already exists for {arn}")
        return
    except service_client.exceptions.ResourceNotFoundException:
        pass

    current = json.loads(
        service_client.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"]
    )

    current["password"] = generate_password()

    service_client.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=json.dumps(current),
        VersionStages=["AWSPENDING"],
    )
    logger.info(f"createSecret: New password generated and stored as AWSPENDING for {arn}")


def set_secret(service_client, arn, token):
    """Set the new password on Aurora using psycopg2."""
    import psycopg2

    pending = json.loads(
        service_client.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)["SecretString"]
    )
    current = json.loads(
        service_client.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"]
    )

    conn = psycopg2.connect(
        host=current["host"],
        port=current.get("port", 5432),
        database=current.get("dbname", "postgres"),
        user=current["username"],
        password=current["password"],
        connect_timeout=5,
    )
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute(
            "ALTER USER %s WITH PASSWORD %s",
            (pending["username"], pending["password"]),
        )
    conn.close()
    logger.info(f"setSecret: Password updated on Aurora for {arn}")


def test_secret(service_client, arn, token):
    """Test the pending secret by connecting to Aurora."""
    import psycopg2

    pending = json.loads(
        service_client.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)["SecretString"]
    )

    conn = psycopg2.connect(
        host=pending["host"],
        port=pending.get("port", 5432),
        database=pending.get("dbname", "postgres"),
        user=pending["username"],
        password=pending["password"],
        connect_timeout=5,
    )
    conn.close()
    logger.info(f"testSecret: Successfully connected to Aurora with pending secret for {arn}")


def finish_secret(service_client, arn, token):
    """Mark the pending secret as current."""
    metadata = service_client.describe_secret(SecretId=arn)
    current_version = None
    for version_id, stages in metadata["VersionIdsToStages"].items():
        if "AWSCURRENT" in stages:
            if version_id == token:
                logger.info(f"finishSecret: Version {token} is already AWSCURRENT for {arn}")
                return
            current_version = version_id
            break

    service_client.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )
    logger.info(f"finishSecret: Rotated secret {arn} successfully, version {token} is now AWSCURRENT")


def generate_password(length=16):
    """Generate a secure random password."""
    chars = string.ascii_letters + string.digits + "!#$%&*()-_=+[]{}<>:?"
    while True:
        pwd = "".join(random.choice(chars) for _ in range(length))
        if (
            any(c.isupper() for c in pwd)
            and any(c.islower() for c in pwd)
            and any(c.isdigit() for c in pwd)
            and any(c in "!#$%&*()-_=+[]{}<>:?" for c in pwd)
        ):
            return pwd
