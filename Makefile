# Convenience targets for the local Slurm cluster.
# Override the Slurm release with e.g. `make build SLURM_VERSION=24.11.7`.

SLURM_VERSION ?= 24.11.7
export SLURM_VERSION

# Container engine; set ENGINE=docker to use Docker instead of Podman.
ENGINE ?= podman
export ENGINE
COMPOSE ?= $(ENGINE) compose

# FEDERATION=1 adds a second cluster (homelab-dc2, "data center 2") and
# federates it with the first; see docs/federation.md. Any other value is off.
override FEDERATION := $(if $(filter 1 yes true,$(FEDERATION)),1,)
export FEDERATION
ifneq ($(FEDERATION),)
export COMPOSE_PROFILES := federation
endif

# SSH key authorised on the login node. Defaults to a project keypair created
# by `make ssh-key`; point SSH_KEY at your own (e.g. ~/.ssh/id_ed25519).
SSH_KEY ?= .ssh/cluster_ed25519
SSH_PORT ?= 2222
export SSH_PORT
export SSH_AUTHORIZED_KEYS := $(shell cat $(SSH_KEY).pub 2>/dev/null)

.PHONY: deps build up down clean logs shell ssh ssh-key web test sync-users fed-demo

deps:  ## Install host dependencies (Podman, Compose, ...) on macOS, RHEL, Debian, Arch or WSL
	./scripts/install_deps.sh

build:  ## Build the Slurm and Slurm-web images locally
	$(COMPOSE) build

up: ssh-key  ## Build if needed and start the cluster
	$(COMPOSE) up -d --build

# down and clean always include the federation profile, so the second cluster
# is stopped too whether or not FEDERATION is set.
down:  ## Stop the cluster, keep volumes (keys, accounting DB, home dirs)
	$(COMPOSE) --profile federation down

clean:  ## Stop the cluster and delete all volumes
	$(COMPOSE) --profile federation down -v

logs:  ## Follow logs from all services
	$(COMPOSE) logs -f

shell:  ## Open a root shell on the controller
	$(ENGINE) exec -it slurm-controller bash

ssh-key:  ## Create the project SSH keypair if it does not exist
	@test -f $(SSH_KEY) || { mkdir -p $(dir $(SSH_KEY)) && ssh-keygen -q -t ed25519 -N "" -C "slurm-podman-cluster" -f $(SSH_KEY); }

ssh:  ## SSH to the login node as hpcuser with the project key
	ssh -i $(SSH_KEY) -p $(SSH_PORT) -o StrictHostKeyChecking=accept-new hpcuser@localhost

sync-users:  ## Create homes and Slurm accounts for LDAP users (after directory changes)
	$(COMPOSE) up --force-recreate --exit-code-from directory-sync directory-sync

web:  ## Open the Slurm-web dashboard
	@if command -v open >/dev/null; then open http://localhost:5011; \
	elif grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then cmd.exe /c start http://localhost:5011; \
	else xdg-open http://localhost:5011; fi

test:  ## Run the smoke test against a running cluster
	./scripts/smoke_test.sh

fed-demo:  ## Show federated jobs spreading across both clusters (needs make up FEDERATION=1)
	./scripts/federation_demo.sh
