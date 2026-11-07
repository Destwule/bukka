# Common tasks. Run `make help` to list them.
API := api
WEB := web
PY  := $(API)/.venv/bin/python

.PHONY: help api-install api-migrate api-seed api-run menu-run orders-run worker-run api-test web-install web-build web-dev setup

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

setup: api-install api-migrate api-seed web-install web-build ## Everything needed for a first run

api-install: ## Create the API virtualenv and install dependencies
	python3 -m venv $(API)/.venv
	$(API)/.venv/bin/pip install -q -e '$(API)[dev]'

api-migrate: ## Create or upgrade the database schema
	cd $(API) && .venv/bin/alembic upgrade head

api-seed: ## Load demo restaurants and dishes (safe to repeat)
	cd $(API) && .venv/bin/python -m bukka_api.seed

api-run: ## Run the API on 0.0.0.0:8080
	cd $(API) && .venv/bin/python -m bukka_api.main

menu-run: ## Run only the menu service on :8081 (restaurants and menus)
	cd $(API) && BUKKA_PORT=8081 .venv/bin/python -m bukka_api.services.menu

orders-run: ## Run only the order service on :8082 (orders and kitchen)
	cd $(API) && BUKKA_PORT=8082 .venv/bin/python -m bukka_api.services.orders

worker-run: ## Run the worker (needs REDIS_URL, e.g. redis://127.0.0.1:6379/0)
	cd $(API) && WORKER_HEALTH_PORT=8083 .venv/bin/python -m bukka_api.worker

api-test: ## Run the API tests
	cd $(API) && .venv/bin/pytest -q

web-install: ## Install web dependencies
	cd $(WEB) && npm ci

web-build: ## Build the web app into web/dist
	cd $(WEB) && npm run build

web-dev: ## Run the web app with hot reload on :5173 (proxies /api to :8080)
	cd $(WEB) && npm run dev
