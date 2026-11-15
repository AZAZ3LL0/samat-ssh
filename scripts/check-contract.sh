#!/usr/bin/env bash
# Contract gate: a change to api/openapi.yaml must bump info.version by exactly 1,
# and generated code may change only together with the contract or the generator setup.
# Usage: check-contract.sh [base-ref] [--staged]
set -euo pipefail

base="${1:-origin/main}"
mode="${2:-}"
spec="api/openapi.yaml"
gen_paths=("agent/internal/api/gen" "ios/Packages/AgentAPI/Sources/Generated")
# Inputs that legitimately change generator output without touching the contract.
generator_inputs=(
  "$spec"
  "agent/internal/api/oapi-codegen.yaml"
  "agent/go.mod"
  "ios/Packages/AgentAPI/openapi-generator-config.yaml"
  "ios/Tools/Package.swift"
  "ios/Tools/Package.resolved"
)

cd "$(git rev-parse --show-toplevel)"

fail() { echo "contract check: $*" >&2; exit 1; }

changed() {
  if [[ "$mode" == "--staged" ]]; then
    git diff --cached --name-only -- "$@"
  else
    git diff --name-only "$base"...HEAD -- "$@"
  fi
}

spec_version() { sed -nE 's/^  version: "([0-9]+)"$/\1/p' | head -n1; }

if [[ "$mode" == "--staged" ]]; then
  # `git show :path` reads the index, so the hook sees exactly what gets committed.
  head_version="$(git show ":$spec" 2>/dev/null | spec_version)"
else
  head_version="$(spec_version <"$spec")"
fi
[[ -n "$head_version" ]] || fail "info.version in $spec must be a quoted integer"

if [[ "$mode" == "--staged" ]]; then
  base_ref="HEAD"
else
  base_ref="$base"
fi
base_version="$(git show "$base_ref:$spec" 2>/dev/null | spec_version || true)"

if [[ -n "$(changed "$spec")" && -n "$base_version" ]]; then
  (( head_version == base_version + 1 )) ||
    fail "$spec changed: bump info.version from $base_version to $((base_version + 1)) (found $head_version)"
fi

if [[ -n "$(changed "${gen_paths[@]}")" && -z "$(changed "${generator_inputs[@]}")" ]]; then
  fail "generated code changed without a contract or generator change; run make generate instead of editing by hand"
fi

# tech.md is kept out of the repository, so this part runs only where the file exists.
if [[ -f tech.md ]]; then
  core_version="$(sed -nE 's/^\*\*Версия ядра: ([0-9]+)\*\*$/\1/p' tech.md | head -n1)"
  [[ "$core_version" == "$head_version" ]] ||
    fail "core version in tech.md ($core_version) differs from info.version ($head_version)"
fi

echo "contract check: ok (version $head_version)"
