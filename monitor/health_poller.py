#!/usr/bin/env python3
import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
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
HOST_DOMAIN = os.getenv("HOST_DOMAIN", "localhost")
NGINX_HTTP_PORT = os.getenv("NGINX_HTTP_PORT", "8080")
INTERVAL_SECONDS = int(os.getenv("HEALTH_INTERVAL_SECONDS", "30"))

failures: dict[str, int] = {}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_state(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_state(path: Path, state: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def write_health(env_id: str, line: str) -> None:
    env_log_dir = LOGS_DIR / env_id
    env_log_dir.mkdir(parents=True, exist_ok=True)
    with (env_log_dir / "health.log").open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def poll_env(state_file: Path) -> None:
    state = load_state(state_file)
    env_id = state["id"]
    url = f"http://127.0.0.1:{NGINX_HTTP_PORT}/health"
    request = urllib.request.Request(url, headers={"Host": f"{env_id}.{HOST_DOMAIN}"})
    started = time.perf_counter()
    status = 0
    error = ""

    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            status = response.status
            response.read()
    except urllib.error.HTTPError as exc:
        status = exc.code
        error = str(exc)
    except Exception as exc:
        error = str(exc)

    latency_ms = round((time.perf_counter() - started) * 1000, 2)
    ok = 200 <= status < 400
    failures[env_id] = 0 if ok else failures.get(env_id, 0) + 1

    write_health(
        env_id,
        json.dumps(
            {
                "timestamp": utc_now(),
                "status": status,
                "latency_ms": latency_ms,
                "ok": ok,
                "failure_count": failures[env_id],
                "error": error,
            }
        ),
    )

    new_status = "running"
    if failures[env_id] >= 3:
        new_status = "degraded"
        print(f"{utc_now()} WARNING {env_id} degraded after 3 failures", flush=True)

    if state.get("status") != new_status:
        state["status"] = new_status
        save_state(state_file, state)


def main() -> None:
    ENVS_DIR.mkdir(exist_ok=True)
    LOGS_DIR.mkdir(exist_ok=True)
    print(f"{utc_now()} health poller started", flush=True)

    while True:
        for state_file in ENVS_DIR.glob("*.json"):
            try:
                poll_env(state_file)
            except Exception as exc:
                print(f"{utc_now()} failed polling {state_file.name}: {exc}", flush=True)
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
