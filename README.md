# DevOps Sandbox Platform

A self-service sandbox platform for short-lived Docker environments. Users can create isolated demo app environments, route to them through Nginx, monitor health, simulate outages, read logs, and destroy the environments manually or automatically after their TTL expires.

## Architecture

```text
Developer / Reviewer
        |
        | make / curl API
        v
+-----------------------------+
| Host Linux VM               |
|                             |
|  Makefile                   |
|  platform/*.sh              |
|  platform/api.py :5000      |
|  cleanup_daemon.sh          |
|  monitor/health_poller.py   |
|                             |
|  Docker                     |
|    sandbox-nginx :8080      |
|      |                      |
|      +-- env-abc-net ------ env-abc-app :8000
|      +-- env-def-net ------ env-def-app :8000
|                             |
|  envs/*.json                |
|  logs/<env-id>/             |
+-----------------------------+
```

## Prerequisites

- One Linux VM
- Docker Engine
- Docker Compose plugin
- Python 3 with `venv` support
- Bash, Make, curl

## Quick Start

From a fresh VM:

```bash
git clone https://github.com/Adeolu1024/devops-sandbox.git devops-sandbox
cd devops-sandbox
cp .env.example .env
make up
make create
```

When `make create` asks for values, enter a name like `demo` and a TTL like `900`.

The script prints a URL like:

```text
http://env-xxxxxxxx.localhost:8080/
```

If your VM does not resolve `*.localhost`, test with curl by forcing the Host header:

```bash
curl -H "Host: env-xxxxxxxx.localhost" http://localhost:8080/
curl -H "Host: env-xxxxxxxx.localhost" http://localhost:8080/health
```

## Full Demo Walkthrough

1. Start the platform:

```bash
make up
```

2. Create a sandbox environment:

```bash
make create
```

Use `demo` as the name and `300` as the TTL for a five-minute environment.

3. Check the running environment:

```bash
curl -H "Host: <env-id>.localhost" http://localhost:8080/
curl -H "Host: <env-id>.localhost" http://localhost:8080/health
```

4. Watch logs:

```bash
make logs ENV=<env-id>
```

5. Show health status:

```bash
make health
```

6. Simulate an outage:

```bash
make simulate ENV=<env-id> MODE=crash
```

Within 90 seconds, the health poller records failures and marks the environment as `degraded`.

7. Recover:

```bash
make simulate ENV=<env-id> MODE=recover
```

8. Destroy manually:

```bash
make destroy ENV=<env-id>
```

If you do not destroy manually, `cleanup_daemon.sh` destroys the environment automatically when the TTL expires.

## API

Start everything with:

```bash
make up
```

Create an environment:

```bash
curl -X POST http://localhost:5000/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"api-demo","ttl":600}'
```

List environments:

```bash
curl http://localhost:5000/envs
```

Destroy an environment:

```bash
curl -X DELETE http://localhost:5000/envs/<env-id>
```

Read the last 100 app log lines:

```bash
curl http://localhost:5000/envs/<env-id>/logs
```

Read the last 10 health checks:

```bash
curl http://localhost:5000/envs/<env-id>/health
```

Trigger outage simulation:

```bash
curl -X POST http://localhost:5000/envs/<env-id>/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"crash"}'
```

## Nginx Network Approach

Nginx runs as a persistent Docker container named `sandbox-nginx`. Each sandbox environment gets a dedicated Docker network and one app container. During creation, the platform connects `sandbox-nginx` to that environment network and writes `nginx/conf.d/<env-id>.conf`.

The generated Nginx config proxies:

```text
<env-id>.localhost -> <env-id>-app:8000
```

During destruction, the config is removed, Nginx is reloaded, the app container is removed, and the dedicated Docker network is deleted.

## Log Shipping

This project uses Approach A from the task brief. During environment creation, the platform starts:

```bash
docker logs -f <container-id> >> logs/<env-id>/app.log &
```

The log shipper PID is saved in `envs/<env-id>.json`. During destruction, that PID is killed so zombie log processes are not left behind. Logs are queryable with:

```bash
make logs ENV=<env-id>
```

On destroy, logs are archived to:

```text
logs/archived/<env-id>/
```

## State Files

Environment state lives in `envs/<env-id>.json` and includes:

- ID
- name
- creation timestamp
- TTL
- status
- container ID/name
- network name
- log shipper PID
- outage mode

State files are written atomically by writing a temporary file first and then moving it into place.

## Make Targets

```bash
make up
make down
make create
make destroy ENV=<env-id>
make logs ENV=<env-id>
make health
make simulate ENV=<env-id> MODE=crash
make clean
```

## Known Limitations

- This is designed for a single Linux VM, not a multi-node cluster.
- The API runs as a local Python process started by `nohup`, not as a production systemd service.
- `crash` recovery restarts the same stopped container; it does not recreate the container from scratch.
- Optional `stress` outage mode is not implemented; supported modes are `crash`, `pause`, `network`, and `recover`.
- Wildcard DNS for `<env-id>.localhost` may vary by environment, so the README shows a reliable `curl -H "Host: ..."` fallback.
- Prometheus and Grafana are not included; health is stored in per-environment log files.

## CI

GitHub Actions validates Python syntax, Bash syntax, and the demo app Docker build on every push and pull request.
