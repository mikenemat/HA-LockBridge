---
name: Bug report
about: A reproducible problem with the bridge or HA integration
title: ''
labels: bug
assignees: ''
---

**Describe the bug**
A clear, one-paragraph description of what's going wrong.

**Reproduce**
1. ...
2. ...
3. See ...

**Expected**
What you thought would happen.

**Component**
- [ ] Bridge (Mac Catalyst Swift app)
- [ ] HomeAssistant integration (`custom_components/ha_lockbridge`)
- [ ] Pairing flow specifically
- [ ] Documentation

**Environment**
- macOS version (bridge host): e.g. 14.4
- Bridge version (CHANGELOG / Marketing Version): e.g. 0.2.0
- HomeAssistant version: e.g. 2024.5.0
- Lock manufacturer + model: e.g. ThorBolt X1 / August Assure Lock 2 Plus
- Bridge host is: [ ] dedicated Mac mini  [ ] VM  [ ] regular laptop

**Bridge logs**
Relevant lines from the bridge's stderr. To capture:
- **Installed `.app` (the normal case):** open Console.app, filter by
  process name `HA-LockBridge`, and copy the recent lines.
- **Building from source:** `cd macos-app && ./build.sh 2> bridge.log`,
  reproduce, attach `bridge.log`.

**HA logs**
Filter by `ha_lockbridge` in Settings → System → Logs and paste the
relevant lines.

**Anything else**
Screenshots, network setup quirks, etc.
