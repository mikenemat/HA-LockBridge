# Security policy

This integration controls **physical door locks**. Security issues are taken
seriously.

## Reporting a vulnerability

**Please do not file public GitHub issues for security-sensitive bugs.**

Email the maintainer at the address listed on the GitHub profile linked from
the project README. Include:

- A description of the issue
- Steps to reproduce
- Affected versions
- Impact assessment if you've thought about it

We aim to respond within a few days and patch within two weeks for clearly
exploitable issues.

## Threat model

The bridge runs on your LAN and is intended to be reachable only from your
local network. The integration is **not designed for internet exposure** —
do not port-forward `:8765` to the open internet.

### What is in scope

- Authentication bypass on `/accessories` or the WebSocket endpoint
- Token leakage from the bridge's config file
- Pair-flow vulnerabilities (e.g. an attacker on the LAN initiating pairings
  the user did not request)
- Any path that lets an unauthorized network peer command a lock

### What is out of scope

- Anyone with read access to the bridge host's filesystem can read the bearer
  tokens. This is by design; protect that host.
- Anyone with HomeKit-controller access to your Apple Home can control your
  locks via Apple Home directly. The bridge is a *secondary* path; the
  primary path's security is governed by Apple Home itself.

## Operational security recommendations

- **Run the bridge on a trusted, well-patched Mac.** Anyone with admin access
  to that machine can read tokens and control your locks.
- **Use WPA2/WPA3 WiFi.** All bridge↔HA traffic is plaintext HTTP; an
  attacker on an open WiFi network could intercept tokens.
- **Don't share the bridge's config file.** It contains tokens that grant
  full lock control.
- **Periodically rotate tokens.** Use the bridge window's **Reset Pairing**
  button to revoke every paired client at once, then re-pair from HA. (Editing
  `paired_clients` in `config.json` by hand is awkward on the App Store build,
  because the file lives inside the app's sandbox container — see the path note
  below — and the running app may rewrite it; Reset Pairing is the supported
  path. A per-client token rotation UI is on the roadmap.)
- **Audit who's paired.** The bridge's window footer shows the number of
  paired clients. The `config.json` in the app's support directory shows their
  names and pair dates.

> **Where `config.json` lives.** The Mac App Store build is sandboxed, so the
> file is inside the app's container:
> `~/Library/Containers/<bundle-id>/Data/Library/Application Support/HALockBridge/config.json`
> (where `<bundle-id>` is the app's bundle identifier, e.g.
> `io.github.mikenemat.HALockBridgeApp`). A self-built, non-sandboxed copy uses
> the classic `~/Library/Application Support/HALockBridge/config.json` instead.

## Known limitations

- **No TLS** between bridge and HA. Acceptable on a trusted LAN; not
  acceptable cross-network.
- **No rate-limit** on pair-initiate endpoint. A malicious LAN peer could
  spam pair requests (each shows up as a window banner on the bridge until
  approved/denied/timed-out).
- **Bearer tokens never expire** once issued. The 5-minute pair-request
  expiry only applies to the request itself, not the resulting token.

These are tracked as issues and PRs are welcome.
