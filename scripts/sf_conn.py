from __future__ import annotations
"""Shared Snowflake connection helper. Reads credentials from .env."""
import os

import snowflake.connector
from dotenv import load_dotenv

load_dotenv()


def get_conn(schema: str | None = None):
    kw = dict(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        role=os.getenv("SNOWFLAKE_ROLE", "SYSADMIN"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "LOAN_WH"),
        database=os.getenv("SNOWFLAKE_DATABASE", "LOAN_RISK"),
    )
    if schema:
        kw["schema"] = schema

    key_file = os.getenv("SNOWFLAKE_PRIVATE_KEY_FILE")
    if key_file:
        kw["authenticator"] = "SNOWFLAKE_JWT"
        kw["private_key_file"] = key_file
        passphrase = os.getenv("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE")
        if passphrase:
            kw["private_key_file_pwd"] = passphrase
    else:
        kw["password"] = os.environ["SNOWFLAKE_PASSWORD"]

    return snowflake.connector.connect(**kw)
