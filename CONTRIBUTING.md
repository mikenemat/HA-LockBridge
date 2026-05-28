# Contributing

Thanks for considering a contribution! This project has two distinct halves —
the Swift Mac Catalyst app (`macos-app/`) and the HomeAssistant Python integration
(`custom_components/ha_lockbridge/`) — and most contributions will touch
only one side at a time.

## Before you start

Open an issue first if your change is non-trivial. Especially:
- Anything that touches the wire protocol between bridge and HA (both sides
  must stay in sync).
- Anything that changes pairing semantics or auth.
- New supported lock manufacturers or model rewrites.

Small, focused PRs land faster than big ones.

## Dev setup

### Bridge (Swift)

```bash
cd macos-app
brew install xcodegen
cp DevelopmentTeam.xcconfig.example DevelopmentTeam.xcconfig
# Edit DevelopmentTeam.xcconfig — set DEVELOPMENT_TEAM to your Apple Team ID
./build.sh
```

The first build of a new bundle ID may need you to open the generated
`HALockBridge.xcodeproj` in Xcode once to grant HomeKit capability via
Apple's Developer portal. After that the CLI build works.

Run with no args to start the bridge in normal mode. Useful test commands:

```bash
./build.sh --toggle "Front Door"   # flip current state
./build.sh --lock "Front Door"     # idempotent lock
./build.sh --unlock "Front Door"   # idempotent unlock
```

### HA integration (Python)

There's no build step — it's a pure Python custom integration. To test on a
real HA instance:

```bash
scp -r custom_components/ha_lockbridge \
  <your-ha-host>:/config/custom_components/
# Restart HA
```

Local syntax/JSON check:

```bash
cd custom_components/ha_lockbridge
for f in *.py; do python3 -m py_compile "$f"; done
python3 -c "import json; json.load(open('manifest.json'))"
python3 -c "import json; json.load(open('strings.json'))"
```

## Code style

- **Swift:** Match the surrounding code. No formatter is enforced.
- **Python:** Roughly black-compatible (4-space indent, 88-ish char lines).
  Type hints encouraged.
- **Comments:** Explain *why*, not *what*. The code shows what.
- **No new TODOs left for someone else.** If you can't finish it now, open an
  issue describing the gap.

## When you change the wire protocol

You must update **both** sides in the same PR:
- `macos-app/Sources/HALockBridge/BridgeServer.swift` — server
- `macos-app/Sources/HALockBridge/AccessoryState.swift` — shared shape
- `custom_components/ha_lockbridge/client.py` — client
- Both READMEs' protocol tables

Bump `manifest.json`'s `version` field whenever you change anything in the HA
integration — HA caches the integration if the version doesn't change.

## Testing

- **Bridge:** the only automated check today is `xcodebuild` (CI runs it).
  Real lock behavior is verified by running against a real Apple Home with
  real locks.
- **HA integration:** local `python -m py_compile` for syntax. End-to-end
  testing is manual against a running HA instance.

Tests are an obvious gap and PRs adding them are very welcome.

## Commit messages

Imperative mood, present tense:
- `bridge: derive lifecycle_state on the server side`
- `ha: filter accessories by enabled IDs from options flow`
- `docs: clarify TCC requirement in README`

A scope prefix (`bridge:`, `ha:`, `docs:`, `ci:`) helps a lot.

## Code of conduct

Be respectful, give people the benefit of the doubt, and assume good intent.
This is a small hobby project — let's keep it pleasant.
