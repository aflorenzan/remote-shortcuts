.DEFAULT_GOAL := help
SHELL := /bin/bash

BUNDLE_ID := com.remoteshortcuts.server

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build in release mode
	swift build -c release

.PHONY: debug
debug: ## Build in debug mode
	swift build

.PHONY: test
test: ## Run the test suite
	swift test

.PHONY: run
run: debug ## Run the server in the foreground (Ctrl-C to stop)
	swift run remote-shortcuts serve

.PHONY: install
install: ## Build, sign, configure and install the LaunchAgent
	@scripts/install.sh

.PHONY: uninstall
uninstall: ## Remove the service (keeps the config)
	@scripts/uninstall.sh

.PHONY: restart
restart: ## Restart the installed service
	launchctl kickstart -k gui/$$(id -u)/$(BUNDLE_ID)

.PHONY: logs
logs: ## Tail the service logs
	tail -f "$$HOME/Library/Logs/remote-shortcuts/server.log" \
		"$$HOME/Library/Logs/remote-shortcuts/server.error.log"

.PHONY: audit
audit: ## Verify the zero-dependency supply-chain guarantee
	@scripts/audit-dependencies.sh

.PHONY: lint
lint: ## Check the shell scripts (requires shellcheck)
	@command -v shellcheck >/dev/null 2>&1 \
		&& shellcheck scripts/*.sh \
		|| echo "shellcheck not installed — skipping"

.PHONY: clean
clean: ## Remove build artefacts
	swift package clean
	rm -rf .build
