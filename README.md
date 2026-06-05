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

> [!IMPORTANT]
> **You need an always-on Mac.** HA-LockBridge is a macOS app — it must run on a
> Mac (a mini, an iMac, or any Mac left powered on) that **stays awake**, is
> signed into the iCloud account your Apple Home uses, and runs **macOS 15
> (Sequoia) or newer**. There is no iOS, iPad, Apple TV, or standalone-hardware
> version; the bridge has to be a logged-in macOS controller in your home. See
> [Requirements](#requirements) for details.

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

> **Advanced users** can build the macOS app themselves with Xcode instead — the
> full source is in [`macos-app/`](macos-app/). Note that a build signed with a
> free Apple Developer account is only valid for **7 days**; after that macOS
> blocks it from launching until you rebuild and re-sign. The Mac App Store build
> has no such expiry, which is why it's the recommended path for everyone else.

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

> **Contributors:** build instructions for the macOS app are in
> [`macos-app/README.md`](macos-app/README.md). (Self-signing caveats are
> covered under [Get the macOS app](#get-the-macos-app) above.)

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

## Performance

**TL;DR** — when your locks are awake, commands from HA feel instant. When
they're asleep, they can take up to ~90 seconds to wake up and respond.
The bridge handles both cases transparently.

HomeKit smart locks aggressively sleep their radios to preserve battery
life. After roughly 5–30 minutes of inactivity (varies by manufacturer and
firmware), they drop their connection to the HomeKit hub and only wake on
direct stimulus — a HomeKey tap, a button press, or the hub poking them.

This gives two very different latency profiles:

| Lock state | What HA sees |
|---|---|
| **Awake** (recently used / actively connected) | Lock entity flips to `locking`/`unlocking` and reaches the final state in **under a second**. |
| **Asleep** (idle for some minutes) | Lock entity flips to `locking`/`unlocking` **immediately** while the bridge wakes the lock in the background. Final state typically lands in **15–60 seconds**; the bridge retries for up to **90 seconds** total. |

### What the bridge does on your behalf

1. HA's command returns successfully in **~100ms** — the bridge accepts it
   optimistically and shows the in-progress state in HA's UI right away.
2. Behind the scenes, the bridge issues the underlying HomeKit write and
   handles HomeKit's `accessoryNotReachable` responses (which is what the
   home hub returns from cached state when it can't currently reach the
   lock). It retries on an exponential backoff (1s, 2s, 4s, 8s, then
   every 16s) for up to 90 seconds total.
3. The moment the lock comes back online, the bridge fires the pending
   write immediately — reachability-recovery short-circuits the backoff
   timer so wake-up paths cost as little time as physically possible.
4. If the retry budget elapses without success, the bridge silently
   reverts the optimistic state — the lock entity flips back to its
   last-known real state in HA's UI without throwing an error toast.
   You can see these revert events on the bridge's *Stats & Debug* page
   under "Lock Errors/Warnings."

### Why this matters

HomeKit's own UI (Apple Home app, HomeKey) does exactly this — when you
tap a HomeKey on a sleeping lock you'll see a brief wait while the
lock wakes up. The bridge mirrors that behaviour for HA, just with a
slightly tighter budget than Apple's (Apple Home will wait longer).

The 90-second budget is empirical: in real-world testing, locks woken
from deep sleep typically respond in 30–60 seconds; 90 seconds covers
nearly all observed wake-up paths while still capping unbounded delays
for the genuinely unreachable case (lock physically off, hub gone, etc.).

## What survives without intervention

- **Mac rename or IP change** → mDNS announces the new hostname for the same UUID; HA's stored entry auto-updates.
- **HA restart** → token persists in HA's config entry; bridge has it in `paired_clients`; reconnect is silent.
- **Bridge restart** → same UUID, same tokens; HA reconnects silently.
- **Network blip** → exponential-backoff reconnect loop in HA's client.
- **Multiple HA instances** → each pairs independently and gets its own token.

## Requirements

| Component | Requirement |
|---|---|
| Bridge host | An **always-on Mac running macOS 15 (Sequoia) or newer**, signed into the iCloud account your Apple Home lives on, on the same LAN as a HomeKit resident (HomePod / Apple TV / iPad). It must stay awake and logged in — sleep or a logged-out session stops the bridge. |
| HomeAssistant | **2026.3+ recommended** — that release added the brand-icon proxy API the integration's logo uses. Manual installs on older HA versions still work fine; only the integration's logo won't appear. (HACS enforces 2026.3.0 as a hard minimum via `hacs.json`, so use the manual install to run on an earlier version.) |
| Network | mDNS / Bonjour must traverse between the bridge host and HA. If HA runs in Docker without `--network=host`, mDNS discovery may need extra config. |

## Caveats

- **The bridge is a controller, not a resident**: it needs an existing HomeKit resident (HomePod / Apple TV / HomePod mini / iPad) on the same network to relay commands when not on the local LAN. If you have those (and you do, if HomeKey works), nothing to configure.
- **Bridge must run in a GUI user session**: HomeKit access requires a logged-in user. On a dedicated Mac, enable auto-login so the bridge can start after a reboot.

## License

MIT — see [LICENSE](LICENSE). Third-party attribution in [NOTICE.md](NOTICE.md).

## Support this project

HA-LockBridge is free and open source. If you find it useful, donations are
welcome to help cover the **$99/year Apple Developer Program** fee that keeps
the macOS app on the Mac App Store — you can
[**sponsor the project on GitHub**](https://github.com/sponsors/mikenemat).
Entirely optional, and much appreciated.
