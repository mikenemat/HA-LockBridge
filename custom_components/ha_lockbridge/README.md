# HA-LockBridge — HomeAssistant integration

This directory holds the HA custom integration that consumes the HTTP + WebSocket
API exposed by the [Mac Catalyst bridge](../macos-app/).

## Install

```bash
scp -r custom_components/ha_lockbridge \
  <your-ha-host>:/config/custom_components/
```

Restart Home Assistant. The bridge announces itself via Bonjour, so a
**HA-LockBridge** card should appear under *Settings → Devices & Services*
within ~10 seconds.

## Setup flow

1. Click **Configure** on the discovered card.
2. **Pair confirm** screen → **Submit**.
3. The bridge's Mac window pops up a pairing request with **Approve / Deny**.
4. Click **Approve** on the bridge → HA's spinner advances.
5. **Device selection** screen: ThorBolt locks pre-checked; others available
   under "Other HomeKit locks" but unchecked by default.
6. Submit → locks appear as devices in HA.

## What you get

For each enabled lock:

- A **Lock entity** with the full 5-state lifecycle (`locked` / `unlocking` /
  `unlocked` / `locking` / `jammed`) — the locking/unlocking animations in
  HA's UI render naturally.
- A **Battery sensor** (if the lock reports battery level).
- A **Jammed binary sensor** (diagnostic).
- A **Low-battery binary sensor** (if the lock reports it).

Devices are grouped by manufacturer in HA's *Devices* view: Sleekpoint
Innovations (ThorBolt) under one group, August Home (Yale/August) under another.

## Reconfigure later

The integration's **Configure** button (gear icon) lets you change which locks
are exposed. Useful when:

- You added a new lock to your Apple Home and want it in HA.
- You want to disable a lock without removing the integration.

The flow re-fetches the bridge's live accessory list (so newly-added locks show
up automatically).

## Files

| File | Purpose |
|---|---|
| `manifest.json` | Integration metadata, declares zeroconf service type. |
| `config_flow.py` | Two-step UI: discovery → pair → device selection. Plus options flow for later. |
| `client.py` | aiohttp HTTP + WebSocket client with auto-reconnect (exp backoff, never gives up). |
| `entity.py` | Base class wiring dispatcher signals to entity state. |
| `lock.py` | Maps the bridge's `lifecycle_state` to HA's `is_locked` / `is_locking` / `is_unlocking` / `is_jammed`. |
| `sensor.py` | Battery level. |
| `binary_sensor.py` | Jammed + low-battery. |
| `const.py` | Constants. |

## Removing the integration

*Settings → Devices & Services → HA-LockBridge → ⋮ → Delete*. The bridge
keeps the token on its side; if you re-add later it'll appear as a new pairing.
You can clean it up on the bridge by removing the entry from
`~/Library/Application Support/HALockBridge/config.json` on the bridge host.
