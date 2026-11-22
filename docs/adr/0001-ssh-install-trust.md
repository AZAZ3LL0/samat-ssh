# 0001. Trust and secrets in the SSH agent install

- Status: accepted
- Date: 2026-11-22
- Slices: S1.3, S1.5

## Context

S1.3 installs `pulse-agent` over SSH and pairs with it; S1.5 updates it the same way. The phone talks to an
SSH server it has never seen, sends the user's password or key, and runs `install.sh` as root. Three questions
need one answer for every SSH connection the app makes:

1. How does the app know it talks to the user's server and not to someone in between?
2. How does a non-root SSH user become root for `install.sh`?
3. Which secrets does the app keep afterwards?

## Decision

**Host key: trust on first use, checked by the user.** Before any credential leaves the phone, the app opens
a connection that only reads the server's host key and shows its fingerprint in OpenSSH form
(`SHA256:<base64>`, the output of `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`). The user compares it
and confirms. The real connection then trusts exactly that key; any other key fails as a host key mismatch
with no "connect anyway" option, as with the agent's TLS pin (tech.md 4.2). The confirmed key is kept in the
Keychain as `ssh.hostkey.<serverId>` (OpenSSH public key line), so later SSH connections (agent update, S1.5)
check it without asking again.

**Root: `sudo -S` with the same password.** A root login runs commands directly. Another user runs them under
`sudo -S -p ''`; the password goes to the command's stdin once and never into the command line, where `ps`
and shell history would show it. A key login without a password works only with passwordless sudo; otherwise
the install stops with an error that says so.

**Secrets.** The SSH password is used for one install and never stored. The app generates its own Ed25519 key
per server, appends the public key to the user's `~/.ssh/authorized_keys`, and keeps the private key in the
Keychain as `ssh.key.<serverId>`. A private key the user pastes for the first login is used once and not
stored. Passwords, keys and pairing codes never reach logs (`Redact`).

## Consequences

- A new Keychain account `ssh.hostkey.<serverId>`; tech.md 8.2 lists it.
- Two TCP connections per install: one to read the host key, one to work.
- A server whose host key changes (reinstall) needs a fresh install from the app.
- Without passwordless sudo, an agent update over SSH (S1.5) asks for the password again.
