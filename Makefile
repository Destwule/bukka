# Common tasks. Run `make help` to list them.
API := api
WEB := web
PY  := $(API)/.venv/bin/python

.PHONY: help api-install api-migrate api-seed api-run api-test web-install web-build web-dev setup

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

api-test: ## Run the API tests
	cd $(API) && .venv/bin/pytest -q

web-install: ## Install web dependencies
	cd $(WEB) && npm ci

web-build: ## Build the web app into web/dist
	cd $(WEB) && npm run build

web-dev: ## Run the web app with hot reload on :5173 (proxies /api to :8080)
	cd $(WEB) && npm run dev
