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

Other solutions — virtual/template switches and automations that sync states and
actions between the two ecosystems — provide basic functionality, but are
brittle. They rely on extensive manual configuration in *both* HomeKit and Home
Assistant, and often fail silently or drift out of sync after minor outages and
communication glitches. They also become frustrating to debug as you scale up to
5–10 locks or more on a larger property. If you only have one or two locks, you
should absolutely attempt that before going all-in on this option — here's a good
[example writeup](https://nils.schimmelmann.us/2025-03-19-schlage-encode-plus-home-assistant/).

> [!CAUTION]
> **HA-LockBridge has three hard environment requirements. Read these before you start.**
>
> - **An always-on Mac.** It's a macOS app — it must run on a Mac (mini, iMac,
>   any Mac left powered on) that stays awake, is signed into your Apple Home's
>   iCloud account, and runs **macOS 15 (Sequoia) or newer**. There is no iOS,
>   iPad, Apple TV, or standalone-hardware version. See
>   [Requirements](#requirements).
> - **Foreground.** Apple's HomeKit lets an app
>   control locks *only* while it is the **frontmost, active app** — an Apple
>   limitation with no workaround. So HA-LockBridge grabs focus every time Home
>   Assistant sends a lock command. **A dedicated Mac mini is strongly
>   recommended**; on a Mac you actively use, it will jump to the front on every
>   lock action. It will restore focus within a few seconds.
> - **An active display device.** A headless Mac with no display has no window
>   context, so the app can't take focus and lock control silently fails. You
>   need a **physical monitor, an HDMI dummy plug, or display software like
>   [BetterDummy / BetterDisplay](https://github.com/waydabber/BetterDisplay)**
>   attached or running at all times. Screen Sharing alone is *not* enough — it
>   only provides a display context while the session is open.

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

https://github.com/user-attachments/assets/c5c490f5-7cfa-4938-8f27-a8e1e7de5c62

## Built for ThorBolt X1, works with any HomeKit lock

The integration was developed with [ThorBolt X1](https://thorbolt.com) (sold by
Sleekpoint Innovations) in mind — it's the lock the author owns and the one that
benefits most from this architecture because of HomeKey support. Any HomeKit
lock works, though — August, Yale, Aqara, Level, **Schlage Encode Plus**,
and others all expose the standard `HMServiceTypeLockMechanism` the bridge
reads and writes.

Several of those locks *do* have first-party Home Assistant integrations, but
they're typically **cloud-polling** (HA talks to the manufacturer's servers,
which talk to the lock) — that means an internet dependency, polling latency,
and another account to keep alive. This bridge is **local-push**: state changes
arrive over your LAN the moment HomeKit sees them, with no cloud in the path.
If your lock has HomeKey (like the ThorBolt X1 or Schlage Encode Plus), the
bridge is also the only way to get it into HA *without unpairing it from Apple
Home and losing HomeKey* — see the [scope FAQ](#faq-why-only-locks) for why
that trade-off matters.

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
2. In the app window, click **Open Login Items…** under *Start at Login* and
   add **HA-LockBridge** in System Settings → General → Login Items, so the
   bridge auto-launches with your Mac. (macOS doesn't let a Mac Catalyst app add
   itself, so this is a quick one-time manual step.)

The bridge runs as a normal foreground app — a Dock icon and a single
always-visible window showing **"Waiting for Home Assistant to pair"**. There
is no menu-bar icon; all controls (Start at Login, Reset Pairing, Quit) live
in the window.

> **Contributors:** build instructions for the macOS app are in
> [`macos-app/README.md`](macos-app/README.md). (Self-signing caveats are
> covered under [Get the macOS app](#get-the-macos-app) above.)

### 2. Install the HA integration

Pick whichever fits:

- **HACS (recommended):** add this repository as a custom integration repository in [HACS](https://hacs.xyz), then install **HA-LockBridge**. HACS handles updates for you.
- **Manual — release zip:** download the latest `ha_lockbridge-<version>.zip` from the [**Releases page**](https://github.com/mikenemat/HA-LockBridge/releases/latest), unzip it, and copy the resulting `ha_lockbridge` folder into `<config>/custom_components/`.
- **Manual — from source:** copy the folder straight out of this repo:
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
| Bridge host | An **always-on, ideally dedicated Mac running macOS 15 (Sequoia) or newer**, signed into the iCloud account your Apple Home lives on, on the same LAN as a HomeKit resident (HomePod / Apple TV / iPad). It must stay awake, logged in, and with **HA-LockBridge as the frontmost app** — it runs as a visible foreground app and keeps the display awake. Using that Mac for other apps will delay lock commands. |
| HomeAssistant | **2026.3+ recommended** — that release added the brand-icon proxy API the integration's logo uses. Manual installs on older HA versions still work fine; only the integration's logo won't appear. (HACS enforces 2026.3.0 as a hard minimum via `hacs.json`, so use the manual install to run on an earlier version.) |
| Network | mDNS / Bonjour must traverse between the bridge host and HA. If HA runs in Docker without `--network=host`, mDNS discovery may need extra config. |

## Caveats

- **The bridge is a controller, not a resident**: it needs an existing HomeKit resident (HomePod / Apple TV / HomePod mini / iPad) on the same network to relay commands when not on the local LAN. If you have those (and you do, if HomeKey works), nothing to configure.
- **Bridge must run in a GUI user session, foreground**: HomeKit access requires a logged-in user, and prompt lock *control* requires the app to be frontmost. On a dedicated Mac, enable auto-login + Start at Login so the bridge comes back frontmost after a reboot.
- **Unavailable vs. optimistic-write tension**: when HomeKit reports a lock as unreachable (`reachable=false`), the HA lock entity goes **unavailable** — yet the bridge will *still accept and queue a write* and heal it the moment the lock wakes (it retries for 90s on an exponential backoff). So an automation that bails on "unavailable" may skip a command the bridge would actually have delivered. If you want a lock command to always be *attempted*, call it regardless of the entity's availability; the bridge does the right thing in the background.

## Dedicated appliance Mac setup

The bridge is happiest on a Mac you don't otherwise touch (a Mac mini is ideal —
see why under [Requirements](#requirements) and the foreground caveat above).
Do these once, in order, to turn that Mac into a hands-off appliance:

1. **Install from the Mac App Store** and launch it once so the HomeKit access
   prompt appears — click **Allow**.
2. **Turn off FileVault** (System Settings → Privacy & Security → FileVault).
   FileVault is **on by default on new Macs**, and it *blocks auto-login* — with
   it on, the Mac sits at the disk-unlock screen after a reboot and the bridge
   never starts. (This is a deliberate trade-off for a dedicated, physically
   secured appliance; don't do it on a laptop you carry around.)
3. **Enable automatic login** for the bridge's user account (System Settings →
   Users & Groups → Automatically log in as). Now a reboot lands you logged in.
4. **Add HA-LockBridge to Login Items** so it auto-launches: in the app window
   click **Open Login Items…** under *Start at Login*, then add **HA-LockBridge**
   under System Settings → General → Login Items. (Mac Catalyst apps can't
   register themselves, so this is a one-time manual step.)
5. **Disable automatic screen lock / "Require password after sleep"** (System
   Settings → Lock Screen). A locked screen has no foreground app, so lock
   *control* fails. Lock the screen *manually* with Control-Command-Q only when
   you walk away and don't need writes for a while.
6. **Turn off Fast User Switching** (System Settings → Control Center → Fast
   User Switching → off), or at least never switch away from the bridge's
   session — switching users backgrounds it and breaks writes.
7. **Restart after a power failure** (System Settings → Energy → "Start up
   automatically after a power failure"). Combined with auto-login + Login
   Items, a power blip brings the bridge all the way back unattended.
8. **Give it a display context.** A headless Mac can't take focus, so the app
   can't control locks. Attach a real monitor, an **HDMI dummy plug**, or run
   **[BetterDummy / BetterDisplay](https://github.com/waydabber/BetterDisplay)**
   as a virtual display. Screen Sharing alone is *not* enough — it only provides
   a display while the session is open.
9. **Leave App Store automatic updates on** (System Settings → App Store → "App
   Updates") so the bridge stays current without you logging in to update it.

## FAQ

<a id="faq-why-only-locks"></a>
**Why is this locks-only? Couldn't it bridge all my HomeKit accessories?**
On purpose. Locks are the one HomeKit category where the *normal* HA path —
unpairing the accessory from Apple Home and pairing it with HA's
`homekit_controller` instead — carries a real cost: it **breaks HomeKey** (and
Apple Home, Siri, and family sharing) for that lock. For lights, switches, and
sensors that cost is near zero, so those are better served by HA's native
integrations or the manufacturers' own. Scoping to locks keeps the bridge small,
keeps its security surface (it can actuate *door locks*) auditable, and avoids
reinventing a general-purpose HomeKit bridge that HA already has a better answer
for. See [What this project IS and ISN'T](CLAUDE.md) for the full rationale.

**Should I use a dedicated Apple ID for the appliance Mac?**
**Recommended, yes.** The bridge needs the Mac signed into the iCloud / Apple
Home account your locks live on, and that account is logged in unattended on a
machine running with auto-login and no screen lock (see the appliance checklist
above). Rather than expose your primary Apple ID that way, create (or reuse) a
**dedicated Apple ID**, invite it to your Apple Home as a **member** (Home app →
Home Settings → invite — member access is enough to control the locks), and sign
*that* account into the appliance Mac. If the appliance is ever compromised, you
revoke one home invitation instead of rotating your main Apple ID.

## License

MIT — see [LICENSE](LICENSE). Third-party attribution in [NOTICE.md](NOTICE.md).

## Support this project

HA-LockBridge is free and open source. If you find it useful, donations are
welcome to help cover the **$99/year Apple Developer Program** fee that keeps
the macOS app on the Mac App Store — you can
[**sponsor the project on GitHub**](https://github.com/sponsors/mikenemat).
Entirely optional, and much appreciated.
