SHELL := /usr/bin/env bash
.EXPORT_ALL_VARIABLES:

-include .env

SYSTEM_PYTHON ?= python3
VENV ?= .venv
PYTHON ?= $(VENV)/bin/python
API_PORT ?= 5000
NGINX_HTTP_PORT ?= 8080
ENV ?=
MODE ?= crash

.PHONY: up down create destroy logs health simulate clean build dirs chmod deps stop-daemons

dirs:
	mkdir -p envs logs logs/archived nginx/conf.d

chmod:
	chmod +x platform/*.sh monitor/health_poller.py platform/api.py platform/list_health.py

build: dirs
	docker build -t sandbox-demo-app:latest platform/demo_app

deps:
	$(SYSTEM_PYTHON) -m venv $(VENV)
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r platform/requirements.txt

stop-daemons:
	@for f in logs/api.pid logs/health_poller.pid logs/cleanup_daemon.pid; do \
		if [ -f "$$f" ]; then kill "$$(cat $$f)" 2>/dev/null || true; rm -f "$$f"; fi; \
	done

up: dirs chmod stop-daemons deps build
	docker compose up -d nginx
	nohup platform/cleanup_daemon.sh >> logs/cleanup.log 2>&1 & echo $$! > logs/cleanup_daemon.pid
	nohup $(PYTHON) monitor/health_poller.py >> logs/health_poller.log 2>&1 & echo $$! > logs/health_poller.pid
	nohup $(PYTHON) platform/api.py >> logs/api.log 2>&1 & echo $$! > logs/api.pid
	@sleep 1
	@for f in logs/api.pid logs/health_poller.pid logs/cleanup_daemon.pid; do \
		kill -0 "$$(cat $$f)" 2>/dev/null || (echo "Failed to start process recorded in $$f" && exit 1); \
	done
	@echo "Platform up"
	@echo "Nginx: http://localhost:$(NGINX_HTTP_PORT)"
	@echo "API: http://localhost:$(API_PORT)"

down: stop-daemons
	@for state in envs/*.json; do \
		if [ -f "$$state" ]; then platform/destroy_env.sh "$$(basename "$$state" .json)" || true; fi; \
	done
	docker compose down

create: dirs chmod
	@read -p "Environment name: " name; \
	read -p "TTL seconds [1800]: " ttl; \
	ttl=$${ttl:-1800}; \
	platform/create_env.sh "$$name" "$$ttl"

destroy:
	@test -n "$(ENV)" || (echo "Usage: make destroy ENV=env-id" && exit 1)
	platform/destroy_env.sh "$(ENV)"

logs:
	@test -n "$(ENV)" || (echo "Usage: make logs ENV=env-id" && exit 1)
	@if [ -f "logs/$(ENV)/app.log" ]; then \
		tail -f "logs/$(ENV)/app.log"; \
	elif [ -f "logs/archived/$(ENV)/app.log" ]; then \
		tail -f "logs/archived/$(ENV)/app.log"; \
	else \
		echo "No app log found for $(ENV)"; exit 1; \
	fi

health:
	@$(PYTHON) platform/list_health.py

simulate:
	@test -n "$(ENV)" || (echo "Usage: make simulate ENV=env-id MODE=crash" && exit 1)
	platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

clean: down
	rm -rf envs logs nginx/conf.d/*.conf
	mkdir -p envs logs logs/archived nginx/conf.d
