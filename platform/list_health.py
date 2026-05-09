#!/usr/bin/env python3
import json
import time
from pathlib import Path

now = int(time.time())
envs_dir = Path("envs")

for path in sorted(envs_dir.glob("*.json")):
    data = json.loads(path.read_text(encoding="utf-8"))
    remaining = max(0, int(data["created_at"]) + int(data["ttl"]) - now)
    print(
        f'{data["id"]}\t{data["name"]}\t{data["status"]}\tTTL remaining: {remaining}s'
    )
