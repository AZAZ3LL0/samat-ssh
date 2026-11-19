#!/bin/sh
# Configures the `vps` SSH host for deploy.sh and check.sh in CI.
# Needs VPS_HOST, VPS_SSH_USER, VPS_SSH_KEY and VPS_KNOWN_HOSTS (see README.md).
set -eu

: "${VPS_HOST:?}" "${VPS_SSH_USER:?}" "${VPS_SSH_KEY:?}" "${VPS_KNOWN_HOSTS:?}"

install -d -m 0700 ~/.ssh
printf '%s\n' "$VPS_SSH_KEY" >~/.ssh/vps
chmod 0600 ~/.ssh/vps
# A pinned host key: CI never trusts the VPS on first use.
printf '%s\n' "$VPS_KNOWN_HOSTS" >>~/.ssh/known_hosts
cat >>~/.ssh/config <<EOF
Host vps
  HostName $VPS_HOST
  User $VPS_SSH_USER
  IdentityFile ~/.ssh/vps
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  BatchMode yes
EOF
