SHELL := /bin/bash
.DEFAULT_GOAL := help

SPEC := api/openapi.yaml
GO_GEN := agent/internal/api/gen
SWIFT_GEN := ios/Packages/AgentAPI/Sources/Generated
IOS_SIMULATOR ?= iPhone 16
IOS_DESTINATION ?= platform=iOS Simulator,name=$(IOS_SIMULATOR)
# Base ref for contract checks; CI passes the PR base.
BASE ?= origin/main

.PHONY: help generate generate-go generate-swift check-generate check-contract validate-fixtures \
	lint lint-go lint-swift test agent-test agent-run agent-it ios-test ios-demo ios-project hooks

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

validate-fixtures: ## check fixtures/ against the contract schemas
	cd agent && go test -count=1 -run '^TestFixtures' ./internal/api/contracttest/

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

ios-test: ## test the iOS packages, then the app and its UI in demo mode
	@# Package tests run from the package's aggregate scheme; Xcode versions name it
	@# differently, so ask instead of hardcoding.
	cd ios/Packages && scheme="$$(xcodebuild -list -json | ../../scripts/first-scheme.py)" && \
		xcodebuild test -scheme "$$scheme" -destination '$(IOS_DESTINATION)' -skipPackagePluginValidation
	xcodebuild test -project ios/Pulse.xcodeproj -scheme Pulse -destination '$(IOS_DESTINATION)' \
		-skipPackagePluginValidation

ios-demo: ## build and run the app in the simulator with -PulseDemo YES: seed data, no network
	xcodebuild build -project ios/Pulse.xcodeproj -scheme Pulse -destination '$(IOS_DESTINATION)' \
		-derivedDataPath .build/ios-demo -skipPackagePluginValidation
	xcrun simctl boot '$(IOS_SIMULATOR)' 2>/dev/null || true
	open -a Simulator
	xcrun simctl install booted .build/ios-demo/Build/Products/Debug-iphonesimulator/Pulse.app
	xcrun simctl launch --terminate-running-process booted dev.azaz3ll0.pulse -PulseDemo YES

ios-project: ## regenerate ios/Pulse.xcodeproj from ios/project.yml (needs xcodegen)
	cd ios && xcodegen generate --spec project.yml

hooks: ## install the pre-commit hook
	ln -sf ../../scripts/pre-commit .git/hooks/pre-commit
