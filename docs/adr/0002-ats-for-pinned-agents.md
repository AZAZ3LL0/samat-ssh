# 0002. App Transport Security for agents with a pinned self-signed key

- Status: accepted
- Date: 2026-11-22
- Slices: S1.1, S1.2 (found on a real device after both merged)

## Context

Every agent serves its own self-signed ECDSA certificate (tech.md 4.2), and the app trusts it only through the
SHA-256 SPKI pin in `PinningDelegate`. On a device every connection still failed with `-9802`, shown as
"server unreachable": App Transport Security evaluates the trust again after the delegate accepted it and rejects
a certificate no system root signed. The unit tests did not catch it because the package test host does not
apply the app's ATS policy.

ATS offers per-domain exceptions, but agents live on whatever host or IP the user types or scans at runtime, so
no `NSExceptionDomains` entry can name them. `NSAllowsLocalNetworking` covers only local addresses, not a VPS.

## Decision

Set `NSAllowsArbitraryLoads = true` in the app's Info.plist (`ios/project.yml`). The SPKI pin remains the only
trust decision for agents: `PinningDelegate` rejects any key other than the pinned one, and a pin mismatch stays
a hard error without a "connect anyway" option.

The flag also allows plain HTTP, which the app does not use: `LiveAgentClient` builds only `https` and `wss`
URLs. Any new network code keeps to that rule.

## Consequences

- Connections to agents work on devices; pinning is unchanged.
- App Store review asks to justify `NSAllowsArbitraryLoads` (S7.4): connections to user-owned servers with
  self-signed certificates guarded by certificate pinning.
- If ATS ever offers a runtime per-connection exception, replace the flag with it.
