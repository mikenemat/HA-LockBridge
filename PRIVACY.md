# Privacy policy

**Short version:** HA-LockBridge collects no data, sends nothing to the internet,
and never talks to any server we operate. Everything runs on hardware you own,
on your local network.

## What data is created

The bridge generates and stores the following on the **bridge host** (your Mac):

| Data | Where | Why |
|---|---|---|
| A random **instance UUID** | `config.json` in the app's support directory (see note below) | Identifies this bridge to your HomeAssistant integration so it can find the bridge again after IP/hostname changes. |
| **Bearer tokens** for paired clients | Same file, mode 0600 | Authenticates HomeAssistant when it talks to the bridge. |
| Names of paired clients (e.g. "Home Assistant at home.local") | Same file | Displayed in the bridge's UI so you can tell which client is paired. |

> **Where the support directory is.** The Mac App Store build is sandboxed, so
> its support directory lives inside the app's container:
> `~/Library/Containers/<bundle-id>/Data/Library/Application Support/HALockBridge/`
> (where `<bundle-id>` is the app's bundle identifier, e.g.
> `io.github.mikenemat.HALockBridgeApp`). A self-built, *non-sandboxed* copy
> instead uses the classic `~/Library/Application Support/HALockBridge/`.

The HomeAssistant integration stores the bearer token and bridge host/port
inside its standard config entry (`/config/.storage/core.config_entries`),
managed by HomeAssistant.

## What's transmitted over the network

Only HTTP and WebSocket traffic between the bridge and HomeAssistant, on your
**local network**, on port `8765`. Specifically:

- Lock state updates (locked/unlocked/jammed/battery)
- Lock commands (lock/unlock from HA)
- Pair-request / pair-approval messages

This traffic is plaintext HTTP/WS (no TLS) because it's local-LAN only by
design — see [SECURITY.md](SECURITY.md) for the threat model.

## What's never transmitted

- No telemetry, analytics, crash reports, or "phone home" of any kind
- No cloud services or third-party APIs
- No data about your locks, your home, or your usage leaves your network

We don't operate any servers. There's nothing to opt out of because nothing
is collected.

## HomeKit + Apple Home data

The bridge uses Apple's `HMHomeManager` framework to access lock accessories
paired in your Apple Home. That access is entirely between the bridge and
macOS — it requires the OS-level "HomeKit access" permission you grant on
first launch, and the data flows only between the OS, the bridge, and (over
your LAN) HomeAssistant.

The bridge does not access any other HomeKit data (cameras, sensors, etc.) — only the
`HMServiceTypeLockMechanism` services it filters for.

## Logs

The bridge writes logs to:
- the app's support directory (config only — no logs; see the path note above)
- `stderr`, captured by the system log when launched as a Login Item
  (viewable via Console.app filtered to HA-LockBridge) or by your
  terminal when run interactively

These logs may include lock names and accessory UUIDs. They do **not** include
bearer tokens — those never leave the bridge's config file or HA's storage,
and the HA integration redacts the WebSocket URL's token query parameter
before logging.

## Children's privacy

This software is not directed at children and does not knowingly collect any
information from anyone (children or otherwise).

## Changes

If anything in this policy changes (e.g. we add an opt-in cloud feature in a
future version), it will be documented in CHANGELOG.md and require explicit
user consent before activation.

## Contact

Open an issue on GitHub or contact the maintainer at the address on the
GitHub profile linked in [README.md](README.md).
