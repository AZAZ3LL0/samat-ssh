# Test VPS

Every push to `main` deploys the agent to the test VPS (`deploy-vps` in `.github/workflows/agent.yml`), then `check-vps` runs the AgentKit pinning and token tests against it from a simulator. Both jobs skip until `VPS_HOST` is set.

## One-time setup

On the VPS (Ubuntu 22.04/24.04 or Debian 12, systemd, cgroup v2):

1. Create a deploy user with passwordless sudo, for example `/etc/sudoers.d/pulse-deploy`: `deploy ALL=(root) NOPASSWD: ALL`. The jobs run `install.sh` and `pulse-agent pair|tokens` as root.
2. Generate a dedicated key pair (`ssh-keygen -t ed25519 -f pulse-deploy -N ''`) and put `pulse-deploy.pub` into the user's `authorized_keys`.
3. Open TCP `7443` to the internet: the macOS runner has no fixed address.

In the GitHub repository settings (Secrets and variables → Actions):

| Kind     | Name              | Value                                            |
|----------|-------------------|--------------------------------------------------|
| Variable | `VPS_HOST`        | VPS address, as the app would dial it            |
| Variable | `VPS_SSH_USER`    | the deploy user                                  |
| Secret   | `VPS_SSH_KEY`     | content of the private key `pulse-deploy`        |
| Secret   | `VPS_KNOWN_HOSTS` | output of `ssh-keyscan -t ed25519 <VPS_HOST>`, checked against the VPS console |

## What the jobs do

- `make agent-dist` builds the archives of the commit; `deploy.sh` installs the one matching the VPS architecture with `install.sh --archive` and waits until `GET /v1/info` reports the new version. The config in `/etc/pulse-agent/` and the certificate in `/var/lib/pulse-agent/` survive upgrades, so the pin stays the same.
- `check.sh` runs `pulse-agent pair --json` over SSH, pairs with curl pinned to the printed fingerprint, runs `make ios-vps-check` (`LiveAgentTests`: pinned `GET /v1/info`, token on REST and WebSocket, `pinMismatch` for another key, `unauthorized` for an unknown token) and revokes the token.

## By hand

```sh
make agent-dist
deploy/vps/deploy.sh https://<host>:7443           # needs a `vps` entry in ~/.ssh/config
deploy/vps/check.sh https://<host>:7443
```
