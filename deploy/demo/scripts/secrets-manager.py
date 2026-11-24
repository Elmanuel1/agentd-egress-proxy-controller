"""Writes or reads one secret in moto. Run inside the moto pod: boto3 ships there."""
import sys

import boto3

client = boto3.client(
    "secretsmanager",
    endpoint_url="http://127.0.0.1:5000",
    region_name="us-east-1",
    aws_access_key_id="test",
    aws_secret_access_key="test",
)
action, secret_id = sys.argv[1], sys.argv[2]
if action == "create":
    client.create_secret(Name=secret_id, SecretString=sys.stdin.read())
else:
    sys.stdout.write(client.get_secret_value(SecretId=secret_id)["SecretString"])
