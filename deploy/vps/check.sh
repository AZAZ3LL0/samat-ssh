#!/bin/sh
# Pairs with a running agent, runs the AgentKit pinning and token tests against it
# (make ios-vps-check) and revokes the token afterwards. CI runs it against the
# test VPS after each deploy.
#
#   deploy/vps/check.sh <agent-url>
#
# AGENT_CMD runs pulse-agent next to the agent; the default reaches the VPS
# through the `vps` host that ssh-setup.sh configures. Against `make agent-run`:
#   AGENT_CMD='agent/bin/pulse-agent --fake --config agent/config.example.yaml' \
#     deploy/vps/check.sh https://127.0.0.1:7443
set -eu

url=${1:?usage: check.sh <agent-url>}
agent=${AGENT_CMD:-ssh vps sudo pulse-agent}

die() {
	echo "check.sh: $*" >&2
	exit 1
}

# $agent holds a command with arguments: word splitting is intended.
# shellcheck disable=SC2086
pairing=$($agent pair --json) || die "pulse-agent pair failed"
fp=$(printf '%s' "$pairing" | jq -er .fp)
code=$(printf '%s' "$pairing" | jq -er .code)

# Pair over a connection pinned to the printed fingerprint, as the app does.
# curl takes the pin in standard base64 with padding; fp is base64url of 32 bytes.
pin=$(printf '%s=' "$fp" | tr '_-' '/+')
response=$(curl -fsS --insecure --pinnedpubkey "sha256//$pin" \
	-H 'Content-Type: application/json' \
	-d "{\"code\":\"$code\",\"deviceName\":\"vps-check\"}" "$url/v1/pair") ||
	die "pairing at $url failed"
token=$(printf '%s' "$response" | jq -er .token)
token_id=$(printf '%s' "$response" | jq -er .tokenId)
[ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::$token"
# shellcheck disable=SC2086
trap '$agent tokens revoke "$token_id" >/dev/null || echo "check.sh: revoke token $token_id by hand" >&2' EXIT

PULSE_VPS_URL=$url PULSE_VPS_PIN=$fp PULSE_VPS_TOKEN=$token make ios-vps-check
