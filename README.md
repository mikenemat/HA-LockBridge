# HA-LockBridge

> A Mac Catalyst bridge that exposes Apple-Home-paired locks to HomeAssistant
> **without losing HomeKey, Apple Home, or any other native Apple integration**.

Most HomeKit-to-HomeAssistant integrations require you to *unpair* your lock from
Apple Home and pair it with HA instead — which kills HomeKey, family sharing, and
Siri control. HA-LockBridge takes a different approach: a small macOS app
running on any always-on Mac (mini, VM, or iCloud-signed-in laptop) registers
itself as a *second* HomeKit controller in your home and exposes its accessories
to HA over a local HTTP + WebSocket API. The lock stays paired with Apple Home;
HA just gets read/write access through the bridge.

## Get the macOS app

**The macOS bridge is distributed exclusively through the Mac App Store.** That
is the only supported way to install it — there is no download, installer, or
notarized release here on GitHub. Apple requires the HomeKit entitlement to ship
via the App Store on macOS (Developer ID / notarized distribution is not
permitted for HomeKit apps), so the App Store is the one and only channel.

<p align="center">
  <a href="https://apps.apple.com/app/id6774393748">
    <strong>➜ Download HA-LockBridge on the Mac App Store</strong>
  </a>
</p>

The companion **Home Assistant integration** is what lives in this repo (see
[Quick start](#quick-start) below) — install that via HACS.

## Demo

https://github.com/user-attachments/assets/9b362233-e16b-4cc6-ab6c-80b62875407c

## Built for ThorBolt X1, works with any HomeKit lock

The integration was developed with [ThorBolt X1](https://thorbolt.com) (sold by
Sleekpoint Innovations) in mind — it's the lock the author owns and the one that
benefits most from this architecture because of HomeKey support. Other HomeKit
locks (August, Yale, Aqara, etc.) work too, but those manufacturers usually have
direct integrations available that are better suited.

When HA discovers the bridge, the device-selection screen splits locks into
**ThorBolt X1 locks (recommended)** and **Other HomeKit locks** — ThorBolts
checked by default, others opt-in.

## Architecture

```
                       ┌──────────────────────────────────────┐
                       │  Apple Home (iCloud-synced)          │
                       │  ┌──────────┐ ┌────────────┐         │
   HomeKey iPhone ──── │  │ ThorBolt │ │ HomePod    │         │
   (NFC unlock)        │  │   X1     │ │ (resident) │         │
                       │  └────┬─────┘ └─────┬──────┘         │
                       └───────┼─────────────┼────────────────┘
                               │             │
                               └─────HAP─────┤
                                             │
                                             ▼
                       ┌──────────────────────────────────────┐
                       │  Mac running HA-LockBridge.app       │
                       │  (signed into your iCloud)           │
                       │                                      │
                       │  • Mac Catalyst Swift app            │
                       │  • Uses HMHomeManager as a 2nd       │
                       │    controller in your Apple Home     │
                       │  • Advertises self via Bonjour       │
                       │  • Serves HTTP + WS on :8765         │
                       └──────────────────┬───────────────────┘
                                          │
                              HTTP + WebSocket (LAN, token auth)
                                          │
                                          ▼
                       ┌──────────────────────────────────────┐
                       │  Home Assistant                      │
                       │  custom_components/ha_lockbridge│
                       │                                      │
                       │  • Zeroconf auto-discovers bridge    │
                       │  • Click-to-pair (no token typing)   │
                       │  • LockEntity per lock (full lifecycle: │
                       │    locked / locking / unlocked /     │
                       │    unlocking / jammed)               │
                       │  • Battery + low-battery sensors     │
                       └──────────────────────────────────────┘
```

## What's in this repo

| Path | What it is |
|---|---|
| [`macos-app/`](macos-app/) | The Mac Catalyst app. SwiftNIO HTTP + WebSocket server, Bonjour advertising, in-app pairing UI, HomeKit framework integration. |
| [`custom_components/ha_lockbridge/`](custom_components/ha_lockbridge/) | The HA custom integration. Auto-discovery via zeroconf, two-step pairing flow, lock/sensor/binary_sensor entities. |

Each has its own README with build/install details.

## Quick start

### 1. Install the macOS bridge from the Mac App Store

Install **[HA-LockBridge from the Mac App Store](https://apps.apple.com/app/id6774393748)**
onto a Mac that stays powered on and is signed into the iCloud account your
Apple Home lives on. On first launch:

1. Click **Allow** on the macOS Home Data access prompt.
2. From the menu bar icon, enable **Start at Login** so the bridge auto-launches with your Mac.

The bridge window appears showing **"Waiting for Home Assistant to pair"**.

> **Contributors:** you can build the app yourself instead of installing from
> the App Store — see [`macos-app/README.md`](macos-app/README.md). A local
> build signed with a free Apple Developer account re-signs every 7 days, so
> end users should always install from the App Store (no such rotation).

### 2. Install the HA integration

Install via [HACS](https://hacs.xyz) by adding this repository as a custom integration repository, or manually:

```bash
scp -r custom_components/ha_lockbridge \
  <your-ha-host>:/config/custom_components/
```

Restart Home Assistant. Within ~10 seconds, **Settings → Devices & Services**
shows a discovered **HA-LockBridge** card.

### 3. Pair

Click **Configure** on the discovered card → **Submit**. The bridge's window
switches to a pairing request with **Approve / Deny** buttons. Click **Approve**.
HA's flow advances to the device-selection screen with your ThorBolts pre-checked.

## What survives without intervention

- **Mac rename or IP change** → mDNS announces the new hostname for the same UUID; HA's stored entry auto-updates.
- **HA restart** → token persists in HA's config entry; bridge has it in `paired_clients`; reconnect is silent.
- **Bridge restart** → same UUID, same tokens; HA reconnects silently.
- **Network blip** → exponential-backoff reconnect loop in HA's client.
- **Multiple HA instances** → each pairs independently and gets its own token.

## Requirements

| Component | Requirement |
|---|---|
| Bridge host | macOS 14+ (Sonoma or later), signed into the iCloud account your Apple Home lives on, on the same LAN as a HomeKit resident (HomePod / Apple TV / iPad). |
| HomeAssistant | 2026.3+ required (brand-icon proxy API added in this release). |
| Network | mDNS / Bonjour must traverse between the bridge host and HA. If HA runs in Docker without `--network=host`, mDNS discovery may need extra config. |

## Caveats

- **The bridge is a controller, not a resident**: it needs an existing HomeKit resident (HomePod / Apple TV / HomePod mini / iPad) on the same network to relay commands when not on the local LAN. If you have those (and you do, if HomeKey works), nothing to configure.
- **Bridge must run in a GUI user session**: HomeKit access requires a logged-in user. On a dedicated Mac, enable auto-login so the bridge can start after a reboot.

## License

MIT — see [LICENSE](LICENSE). Third-party attribution in [NOTICE.md](NOTICE.md).
