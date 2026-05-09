import os
import socket
from datetime import datetime, timezone

from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/")
def index():
    env_id = os.getenv("SANDBOX_ENV_ID", "unknown")
    env_name = os.getenv("SANDBOX_ENV_NAME", "sandbox")
    return jsonify(
        {
            "message": "Hello from the sandbox demo app",
            "env_id": env_id,
            "name": env_name,
            "hostname": socket.gethostname(),
        }
    )


@app.get("/health")
def health():
    return jsonify(
        {
            "status": "ok",
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }
    )
