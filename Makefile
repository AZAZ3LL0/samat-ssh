SHELL := /bin/bash
.DEFAULT_GOAL := help

SPEC := api/openapi.yaml
GO_GEN := agent/internal/api/gen
SWIFT_GEN := ios/Packages/AgentAPI/Sources/Generated
IOS_DESTINATION ?= platform=iOS Simulator,name=iPhone 16
# Base ref for contract checks; CI passes the PR base.
BASE ?= origin/main

.PHONY: help generate generate-go generate-swift check-generate check-contract \
	lint lint-go lint-swift test agent-test agent-run agent-it ios-test hooks

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "%-18s %s\n", $$1, $$2}'

generate: generate-go generate-swift ## regenerate Go server and Swift client from the contract

generate-go:
	cd agent && go tool oapi-codegen -config internal/api/oapi-codegen.yaml ../$(SPEC)

generate-swift:
	swift run --package-path ios/Tools swift-openapi-generator generate $(SPEC) \
		--config ios/Packages/AgentAPI/openapi-generator-config.yaml \
		--output-directory $(SWIFT_GEN)

check-generate: generate ## fail if generated code is stale or hand-edited
	@# git status also catches new untracked files, which git diff ignores.
	@git status --short -- $(GO_GEN) $(SWIFT_GEN)
	@test -z "$$(git status --porcelain -- $(GO_GEN) $(SWIFT_GEN))" || \
		{ git diff -- $(GO_GEN) $(SWIFT_GEN); echo 'generated code is stale: run make generate and commit'; exit 1; }

check-contract: ## fail on a contract change without a version bump
	scripts/check-contract.sh $(BASE)

lint: lint-go lint-swift ## run all linters

lint-go:
	cd agent && golangci-lint run ./...

lint-swift:
	swiftlint lint --strict --quiet
	git ls-files -z 'ios/*.swift' ':(exclude)$(SWIFT_GEN)' | xargs -0 swift format lint --strict

test: agent-test ios-test ## run all tests

agent-test: ## go test ./...
	cd agent && go test ./...

agent-run: ## run the agent in fake mode: no root, Docker or systemd needed
	cd agent && go run ./cmd/pulse-agent --fake --config config.example.yaml

agent-it: ## build the agent image and run the API tests against a container
	cd agent && go test -tags integration -count=1 ./integration/...

ios-test: ## test the iOS package in the simulator
	@# Xcode versions name the package scheme differently; ask instead of hardcoding
	@# until the app project and its Pulse scheme exist.
	cd ios/Packages && scheme="$$(xcodebuild -list -json | ../../scripts/first-scheme.py)" && \
		xcodebuild test -scheme "$$scheme" -destination '$(IOS_DESTINATION)' -skipPackagePluginValidation

hooks: ## install the pre-commit hook
	ln -sf ../../scripts/pre-commit .git/hooks/pre-commit
