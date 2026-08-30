# agentbox — thin wrapper around docker compose.
# Everything here is a one-liner you can also run by hand.

SHELL := /bin/bash
COMPOSE ?= docker compose

# Read a few values out of .env without sourcing the whole file.
env_value = $(shell [ -f .env ] && grep -E '^$(1)=' .env | tail -1 | cut -d= -f2- | tr -d '"'"'"'" ')
SSH_PORT ?= $(or $(call env_value,SSH_PORT),2222)
SSH_HOST ?= localhost
SSH_USER ?= dev
VOLUME   ?= $(or $(call env_value,AGENTBOX_VOLUME),agentbox-home)
SERVICE  ?= agentbox

.DEFAULT_GOAL := help

help: ## Show this help
	@echo "agentbox — make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  ssh port: $(SSH_PORT)   volume: $(VOLUME)"

key: ## Print this machine's SSH public key (creates one if missing)
	@if ! ls ~/.ssh/id_*.pub >/dev/null 2>&1; then \
	  echo "no key found, creating ~/.ssh/id_ed25519"; \
	  ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "$$(whoami)@$$(hostname)"; \
	fi
	@cat ~/.ssh/id_*.pub

init: ## Create .env from .env.example with your public key filled in
	@test ! -f .env || { echo ".env already exists — edit it by hand"; exit 1; }
	@$(MAKE) --no-print-directory key >/dev/null
	@key="$$(cat ~/.ssh/id_*.pub | head -1)"; \
	  sed "s|^SSH_PUBLIC_KEY=.*|SSH_PUBLIC_KEY=\"$$key\"|" .env.example > .env
	@echo "wrote .env — review it, then run: make up"

build: ## Build the image
	$(COMPOSE) build

up: ## Build if needed and start the box
	$(COMPOSE) up -d
	@echo
	@$(MAKE) --no-print-directory hint

hint:
	@echo "connect with:  ssh -p $(SSH_PORT) $(SSH_USER)@$(SSH_HOST)"
	@echo "then run:      herdr"

down: ## Stop the box (the volume, and everything in it, stays)
	$(COMPOSE) down

restart: ## Restart the box
	$(COMPOSE) restart

logs: ## Follow the container logs
	$(COMPOSE) logs -f

ps: ## Show container status
	$(COMPOSE) ps

ssh: ## SSH into the box from this machine
	ssh -p $(SSH_PORT) $(SSH_USER)@$(SSH_HOST)

shell: ## Open a shell inside the box without SSH (rescue hatch)
	$(COMPOSE) exec -u $(SSH_USER) $(SERVICE) bash -l

root: ## Open a root shell inside the box
	$(COMPOSE) exec -u root $(SERVICE) bash -l

update: ## Rebuild with the latest agent versions and recreate (volume is kept)
	$(COMPOSE) build --pull --build-arg AGENTS_CACHEBUST=$$(date +%Y%m%d%H%M)
	$(COMPOSE) up -d --force-recreate
	@$(MAKE) --no-print-directory hint

backup: ## Tar the home volume into ./backups
	@mkdir -p backups
	@out="backups/$(VOLUME)-$$(date +%Y%m%d-%H%M%S).tar.gz"; \
	  docker run --rm -v $(VOLUME):/data:ro -v "$$PWD/backups:/backup" \
	    ubuntu:24.04 tar czf "/backup/$$(basename $$out)" -C /data . ; \
	  echo "wrote $$out"

restore: ## Restore a backup: make restore FILE=backups/xxx.tar.gz
	@test -n "$(FILE)" || { echo "usage: make restore FILE=backups/xxx.tar.gz"; exit 1; }
	@test -f "$(FILE)" || { echo "no such file: $(FILE)"; exit 1; }
	$(COMPOSE) down
	docker run --rm -v $(VOLUME):/data -v "$$PWD/$$(dirname $(FILE)):/backup" \
	  ubuntu:24.04 tar xzf "/backup/$$(basename $(FILE))" -C /data
	$(COMPOSE) up -d

destroy: ## Delete the container AND the home volume (irreversible)
	@echo "This deletes the volume '$(VOLUME)' and everything in it."
	@read -r -p "Type the volume name to confirm: " answer; \
	  [ "$$answer" = "$(VOLUME)" ] || { echo "aborted"; exit 1; }
	$(COMPOSE) down -v

.PHONY: help key init build up hint down restart logs ps ssh shell root update backup restore destroy
