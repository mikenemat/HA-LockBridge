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

> [!IMPORTANT]
> **The app must stay in the foreground, and it will steal focus.** Apple's
> HomeKit only lets an app control accessories (lock/unlock) while it is the
> **frontmost, active app** — a backgrounded app's commands get deferred or
> stalled. This is an **Apple limitation with no workaround**. So that locks
> respond promptly, HA-LockBridge **grabs focus every time Home Assistant
> sends a lock command**. On a **dedicated Mac mini** (nothing else running on
> it) you'll never notice. On a Mac you actively use, expect the bridge to
> jump to the front whenever a lock is operated — usable, but a little
> annoying. **A dedicated Mac mini is strongly recommended.** See
> [Runs as a foreground app](#runs-as-a-foreground-app--and-why).

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

> ⚠️ **Placeholder — a new demo video is needed.** The previous clip is out of
> date (it predates the foreground-app redesign and shows the old menu-bar UI).
> A fresh recording of the current flow is TODO.

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
2. In the app window, flip the **Start at Login** toggle so the bridge
   auto-launches with your Mac.

The bridge runs as a normal foreground app — a Dock icon and a single
always-visible window showing **"Waiting for Home Assistant to pair"**. There
is no menu-bar icon; all controls (Start at Login, Reset Pairing, Quit) live
in the window. See [Runs as a foreground app](#runs-as-a-foreground-app--and-why)
for why it stays in front.

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

## Runs as a foreground app — and why

HA-LockBridge runs as a **normal foreground Mac app**, not a hidden menu-bar
utility. It shows a Dock icon and a single always-visible window, and it
**comes to the front whenever Home Assistant sends a lock command**.

This is deliberate. Apple's HomeKit only services accessory *writes*
(lock/unlock) promptly for the **frontmost, active app** — a backgrounded or
hidden controller has its writes deferred by tens of seconds, or stalled
until something brings it forward. This is a documented HomeKit limitation,
not something an app can opt out of (even Apple's own App Intents
foreground-continuation API resolves "background work that needs a
capability" by bringing the app to the foreground). So the bridge keeps
itself visible and active, and grabs focus for the instant HA issues a write.

What this means in practice:

- **Run it on a dedicated Mac** — a Mac mini in a closet is ideal. The bridge
  must be the active app to control locks reliably; if you actively use that
  Mac for other things, lock commands lag whenever another app is frontmost.
- **The window can't be closed or minimized** (either would background the
  app). Stop the bridge with the in-window **Quit** button or ⌘Q.
- **It keeps the display awake** so the screen never locks — a locked screen
  drops the app out of the active state. Set the Mac to never sleep for best
  results.
- **All controls live in the window**: Start at Login, Reset Pairing, Quit.
  There is no menu-bar icon.

## What survives without intervention

- **Mac rename or IP change** → mDNS announces the new hostname for the same UUID; HA's stored entry auto-updates.
- **HA restart** → token persists in HA's config entry; bridge has it in `paired_clients`; reconnect is silent.
- **Bridge restart** → same UUID, same tokens; HA reconnects silently.
- **Network blip** → exponential-backoff reconnect loop in HA's client.
- **Multiple HA instances** → each pairs independently and gets its own token.

## Requirements

| Component | Requirement |
|---|---|
| Bridge host | An **always-on, ideally dedicated Mac running macOS 15 (Sequoia) or newer**, signed into the iCloud account your Apple Home lives on, on the same LAN as a HomeKit resident (HomePod / Apple TV / iPad). It must stay awake, logged in, and with **HA-LockBridge as the frontmost app** — it runs as a visible foreground app (see ["Runs as a foreground app"](#runs-as-a-foreground-app--and-why)) and keeps the display awake. Using that Mac for other apps will delay lock commands. |
| HomeAssistant | **2026.3+ recommended** — that release added the brand-icon proxy API the integration's logo uses. Manual installs on older HA versions still work fine; only the integration's logo won't appear. (HACS enforces 2026.3.0 as a hard minimum via `hacs.json`, so use the manual install to run on an earlier version.) |
| Network | mDNS / Bonjour must traverse between the bridge host and HA. If HA runs in Docker without `--network=host`, mDNS discovery may need extra config. |

## Caveats

- **The bridge is a controller, not a resident**: it needs an existing HomeKit resident (HomePod / Apple TV / HomePod mini / iPad) on the same network to relay commands when not on the local LAN. If you have those (and you do, if HomeKey works), nothing to configure.
- **Bridge must run in a GUI user session, foreground**: HomeKit access requires a logged-in user, and prompt lock *control* requires the app to be frontmost (see ["Runs as a foreground app"](#runs-as-a-foreground-app--and-why)). On a dedicated Mac, enable auto-login + Start at Login so the bridge comes back frontmost after a reboot.

## License

MIT — see [LICENSE](LICENSE). Third-party attribution in [NOTICE.md](NOTICE.md).

## Support this project

HA-LockBridge is free and open source. If you find it useful, donations are
welcome to help cover the **$99/year Apple Developer Program** fee that keeps
the macOS app on the Mac App Store — you can
[**sponsor the project on GitHub**](https://github.com/sponsors/mikenemat).
Entirely optional, and much appreciated.
