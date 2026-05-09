#!/usr/bin/env python3
import json
import os
import re
import subprocess
import time
from pathlib import Path

from flask import Flask, jsonify, request

ROOT = Path(__file__).resolve().parents[1]
PLATFORM_DIR = ROOT / "platform"
ENVS_DIR = ROOT / "envs"
LOGS_DIR = ROOT / "logs"


def load_dotenv() -> None:
    env_file = ROOT / ".env"
    if not env_file.exists():
        return
    for raw_line in env_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


load_dotenv()

app = Flask(__name__)
ENV_ID_RE = re.compile(r"^env-[0-9]+-[a-f0-9]{6}$")


def run_script(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(PLATFORM_DIR / args[0]), *args[1:]],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def state_path_for(env_id: str) -> Path:
    return ENVS_DIR / f"{env_id}.json"


def validate_env_id(env_id: str) -> tuple[bool, tuple | None]:
    if not ENV_ID_RE.match(env_id):
        return False, (jsonify({"error": f"invalid env id: {env_id}"}), 400)
    return True, None


def env_exists(env_id: str) -> bool:
    return state_path_for(env_id).exists()


def tail(path: Path, lines: int) -> list[str]:
    if not path.exists():
        return []
    data = path.read_text(encoding="utf-8", errors="replace").splitlines()
    return data[-lines:]


@app.post("/envs")
def create_env():
    body = request.get_json(silent=True) or {}
    name = str(body.get("name", "api-env"))
    ttl = str(body.get("ttl", os.getenv("DEFAULT_TTL_SECONDS", "1800")))
    result = run_script("create_env.sh", name, ttl)
    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip(), "output": result.stdout.strip()}), 500
    return jsonify({"output": result.stdout.strip()}), 201


@app.get("/envs")
def list_envs():
    now = int(time.time())
    envs = []
    for state_file in sorted(ENVS_DIR.glob("*.json")):
        state = read_json(state_file)
        remaining = max(0, int(state["created_at"]) + int(state["ttl"]) - now)
        state["ttl_remaining"] = remaining
        envs.append(state)
    return jsonify(envs)


@app.delete("/envs/<env_id>")
def destroy_env(env_id: str):
    ok, error = validate_env_id(env_id)
    if not ok:
        return error
    result = run_script("destroy_env.sh", env_id)
    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip(), "output": result.stdout.strip()}), 404
    return jsonify({"output": result.stdout.strip()})


@app.get("/envs/<env_id>/logs")
def env_logs(env_id: str):
    ok, error = validate_env_id(env_id)
    if not ok:
        return error
    active_log = LOGS_DIR / env_id / "app.log"
    archived_log = LOGS_DIR / "archived" / env_id / "app.log"
    if active_log.exists():
        return jsonify({"env": env_id, "source": "active", "lines": tail(active_log, 100)})
    if archived_log.exists():
        return jsonify({"env": env_id, "source": "archived", "lines": tail(archived_log, 100)})
    if not env_exists(env_id):
        return jsonify({"error": f"environment not found: {env_id}"}), 404
    return jsonify({"env": env_id, "source": "active", "lines": []})


@app.get("/envs/<env_id>/health")
def env_health(env_id: str):
    ok, error = validate_env_id(env_id)
    if not ok:
        return error
    active_log = LOGS_DIR / env_id / "health.log"
    archived_log = LOGS_DIR / "archived" / env_id / "health.log"
    if active_log.exists():
        return jsonify({"env": env_id, "source": "active", "checks": tail(active_log, 10)})
    if archived_log.exists():
        return jsonify({"env": env_id, "source": "archived", "checks": tail(archived_log, 10)})
    if not env_exists(env_id):
        return jsonify({"error": f"environment not found: {env_id}"}), 404
    return jsonify({"env": env_id, "source": "active", "checks": []})


@app.post("/envs/<env_id>/outage")
def outage(env_id: str):
    ok, error = validate_env_id(env_id)
    if not ok:
        return error
    body = request.get_json(silent=True) or {}
    mode = str(body.get("mode", "crash"))
    result = run_script("simulate_outage.sh", "--env", env_id, "--mode", mode)
    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip(), "output": result.stdout.strip()}), 500
    return jsonify({"output": result.stdout.strip()})


if __name__ == "__main__":
    host = os.getenv("API_HOST", "0.0.0.0")
    port = int(os.getenv("API_PORT", "5000"))
    app.run(host=host, port=port)
