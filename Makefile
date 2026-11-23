# Makefile — local Docker workflow. Run `make help` for the list of targets.
# Only Docker and make are required; all tools run in containers.

SHELL := /bin/bash
.DEFAULT_GOAL := help

IMAGE ?= ghcr.io/okarabudka/media-optimize-tools
SHELLCHECK_IMAGE := koalaman/shellcheck:v0.11.0
SHFMT_IMAGE := mvdan/shfmt:v3.12.0
SCRIPTS := bin/mot run.sh lib/*.sh tests/*.bash tests/*.bats
SHFMT_FLAGS := -i 4 -ci
DOCKER_SRC := docker run --rm -v "$(CURDIR)":/src -w /src

.PHONY: help image test lint fmt

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-6s\033[0m %s\n", $$1, $$2}'

image: ## Build the runtime image
	docker build --target runtime -t $(IMAGE) .

test: ## Run the bats tests in the test image
	docker build --target test -t $(IMAGE):test .
	docker run --rm $(IMAGE):test

lint: ## Run shellcheck and shfmt (diff only)
	$(DOCKER_SRC) $(SHELLCHECK_IMAGE) -x $(SCRIPTS)
	$(DOCKER_SRC) $(SHFMT_IMAGE) $(SHFMT_FLAGS) -d $(SCRIPTS)

fmt: ## Format the shell scripts with shfmt
	$(DOCKER_SRC) -u "$$(id -u):$$(id -g)" $(SHFMT_IMAGE) $(SHFMT_FLAGS) -w $(SCRIPTS)
