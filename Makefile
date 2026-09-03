# agentbox — thin wrapper around docker compose.
# Everything here is a one-liner you can also run by hand.

SHELL := /bin/bash
COMPOSE ?= docker compose

# Read a few values out of .env without sourcing the whole file.
env_value = $(shell [ -f .env ] && grep -E '^$(1)=' .env | tail -1 | cut -d= -f2- | tr -d '"'"'"'" ')
SSH_PORT ?= $(or $(call env_value,SSH_PORT),2222)
SSH_HOST ?= localhost
SSH_USER ?= dev
# What a mirror dials. `make ssh` reaches the box over the published port on
# this machine; a mirror is created from wherever you are, so it needs the
# address the box answers to — AGENTBOX_SSH_HOST when .env names one.
MIRROR_HOST ?= $(or $(call env_value,AGENTBOX_SSH_HOST),$(SSH_HOST))
MIRROR_PORT ?= $(or $(call env_value,AGENTBOX_SSH_PORT),$(SSH_PORT))
VOLUME   ?= $(or $(call env_value,AGENTBOX_VOLUME),agentbox-home)
STATE    ?= $(or $(call env_value,AGENTBOX_STATE_VOLUME),agentbox-state)
DOCKER_VOL ?= $(or $(call env_value,AGENTBOX_DOCKER_VOLUME),agentbox-docker)
SERVICE  ?= agentbox
IMAGE    ?= $(or $(call env_value,AGENTBOX_IMAGE),agentbox:local)

.DEFAULT_GOAL := help

help: ## Show this help
	@echo "agentbox — make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  ssh port: $(SSH_PORT)   volumes: $(VOLUME), $(STATE)"

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

down: ## Stop the box (both volumes, and everything in them, stay)
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

update: ## Rebuild with the latest agents and recreate (volumes are kept)
	$(COMPOSE) build --pull --build-arg AGENTS_CACHEBUST=$$(date +%Y%m%d%H%M)
	$(COMPOSE) up -d --force-recreate
	@$(MAKE) --no-print-directory hint

backup: ## Tar both volumes into ./backups
	@mkdir -p backups
	@stamp="$$(date +%Y%m%d-%H%M%S)"; \
	  for vol in $(VOLUME) $(STATE); do \
	    docker volume inspect "$$vol" >/dev/null 2>&1 || continue; \
	    out="backups/$$vol-$$stamp.tar.gz"; \
	    docker run --rm -v "$$vol":/data:ro -v "$$PWD/backups:/backup" \
	      ubuntu:24.04 tar czf "/backup/$$(basename $$out)" -C /data . ; \
	    echo "wrote $$out"; \
	  done

restore: ## Restore a backup: make restore FILE=... [VOLUME=agentbox-state]
	@test -n "$(FILE)" || { echo "usage: make restore FILE=backups/xxx.tar.gz"; exit 1; }
	@test -f "$(FILE)" || { echo "no such file: $(FILE)"; exit 1; }
	$(COMPOSE) down
	docker run --rm -v $(VOLUME):/data -v "$$PWD/$$(dirname $(FILE)):/backup" \
	  ubuntu:24.04 tar xzf "/backup/$$(basename $(FILE))" -C /data
	$(COMPOSE) up -d

# ---------------------------------------------------------------------------
# Mirroring — the same project here and in the box (docs/mirror.md)
#
# Inside the box `agentbox-mirror` prints these commands for you to paste.
# Here you already have the endpoint in .env, so printing it would be a step
# too many. Mutagen runs on this machine: the box is only the far end.
# ---------------------------------------------------------------------------
# The one ignore list, read out of the script the image ships, so the two sides
# cannot drift apart.
MIRROR_IGNORES = $(shell sed -n "s/^IGNORES='\(.*\)'$$/\1/p" image/etc/mirror.sh)
LOCAL ?= mirrors/$(PROJECT)

# Same rule the box uses: lowercase, and anything Mutagen will not take in a
# session name becomes a dash.
mirror_session = agentbox-$(shell printf '%s' "$(PROJECT)" | tr '[:upper:]' '[:lower:]' \
                   | sed -e 's/[^a-z0-9_-]\+/-/g' -e 's/-\+/-/g' -e 's/^-//' -e 's/-$$//')

# A "command not found" from make is a worse answer than saying where to get it.
define need_mutagen
	@command -v mutagen >/dev/null 2>&1 || { \
	  echo "mutagen is not installed on this machine — it is the client, and it"; \
	  echo "runs here, not in the box. Install it with one of:"; \
	  echo ""; \
	  echo "  macOS    brew install mutagen-io/mutagen/mutagen"; \
	  echo "  Linux    untar the release for your architecture from"; \
	  echo "           https://github.com/mutagen-io/mutagen/releases into ~/.local/bin"; \
	  echo "  Windows  scoop install mutagen"; \
	  echo ""; \
	  echo "See docs/mirror.md."; \
	  exit 1; \
	}
endef

mirror: ## Mirror a project onto this machine: make mirror PROJECT=app [LOCAL=path]
	$(need_mutagen)
	@test -n "$(PROJECT)" || { echo "usage: make mirror PROJECT=<name> [LOCAL=<path>]"; exit 1; }
	@mkdir -p "$(LOCAL)"
	mutagen sync create \
	  --name=$(mirror_session) \
	  --ignore='$(MIRROR_IGNORES)' \
	  "$(LOCAL)" \
	  "$(SSH_USER)@$(MIRROR_HOST):$(MIRROR_PORT):/home/$(SSH_USER)/projects/$(PROJECT)"
	@echo
	@echo "mirroring /home/$(SSH_USER)/projects/$(PROJECT) into $(LOCAL)"
	@echo "watch the first sync with: mutagen sync monitor $(mirror_session)"

mirror-status: ## Show the mirrors this repository created
	$(need_mutagen)
	@# Sessions belong to the local daemon, not to this repository: this only
	@# filters the ones named with the box's prefix, and a session renamed by
	@# hand drops out of the view. `mutagen sync list` is the whole truth.
	@out="$$(mutagen sync list 2>/dev/null | awk ' \
	    /^-{10,}$$/ { if (keep) printf "%s", block; block=""; keep=0; next } \
	    { block = block $$0 "\n"; if ($$0 ~ /^Name: agentbox-/) keep = 1 } \
	    END { if (keep) printf "%s", block }')"; \
	  if [ -n "$$out" ]; then printf '%s\n' "$$out"; \
	  else echo "no agentbox mirrors right now — 'mutagen sync list' shows every session"; fi

unmirror: ## Stop mirroring a project (neither copy is deleted): make unmirror PROJECT=app
	$(need_mutagen)
	@test -n "$(PROJECT)" || { echo "usage: make unmirror PROJECT=<name>"; exit 1; }
	mutagen sync terminate $(mirror_session)
	@echo "stopped — both copies of the files are still there"

test: build ## Boot the image and check that persistence really works
	tests/persistence.sh $(IMAGE)

test-docker: build ## Check the box's own Docker daemon end to end
	tests/docker.sh $(IMAGE)

test-mirror: build ## Check what the box tells you about mirroring
	tests/mirror.sh $(IMAGE)

persist: ## Show what survives a recreate (packages and files kept)
	$(COMPOSE) exec $(SERVICE) agentbox-persist status

destroy: ## Delete the container AND both volumes — the fresh start (irreversible)
	@echo "This deletes '$(VOLUME)' (your home), '$(STATE)' (packages and"
	@echo "system changes) and '$(DOCKER_VOL)' (Docker images and containers),"
	@echo "and everything in them. The box comes back as a plain image."
	@read -r -p "Type the volume name to confirm: " answer; \
	  [ "$$answer" = "$(VOLUME)" ] || { echo "aborted"; exit 1; }
	$(COMPOSE) down -v

.PHONY: help key init build up hint down restart logs ps ssh shell root update backup restore test test-docker test-mirror mirror mirror-status unmirror persist destroy
