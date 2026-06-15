"""Deeper integration tests that need the Home Assistant test rig.

These require `pytest` + `pytest-homeassistant-custom-component` (and therefore
`homeassistant`, `aiohttp`, `voluptuous`). The dev/CI base image used for the
quick `python3 -m py_compile` / fallback test pass does NOT have these, so the
whole module is skipped cleanly when the rig is absent — importing it under a
bare interpreter must not raise.

When the rig IS present (`pip install pytest-homeassistant-custom-component`),
these exercise the client's WS message handling and the back-compat contract
against a fake bridge.
"""
from __future__ import annotations

import importlib.util

# --- Guard: skip the entire module unless the HA test rig is importable. ----
_HAS_HA = all(
    importlib.util.find_spec(mod) is not None
    for mod in ("homeassistant", "aiohttp", "voluptuous")
)

if not _HAS_HA:  # pragma: no cover - exercised only on the bare interpreter
    # Importable on a bare interpreter (no pytest, no homeassistant): define a
    # module-level skip marker only if pytest is around; otherwise this module
    # is simply an importable no-op so the fallback test runner doesn't choke.
    try:
        import pytest

        pytestmark = pytest.mark.skip(
            reason="homeassistant test rig not installed "
            "(pytest-homeassistant-custom-component)"
        )
    except ModuleNotFoundError:
        pass
else:  # pragma: no cover - exercised only with the rig installed
    import asyncio
    from types import SimpleNamespace
    from unittest.mock import MagicMock

    import pytest

    from custom_components.ha_lockbridge.client import LockBridgeClient
    from custom_components.ha_lockbridge.const import (
        EVENT_WRITE_REVERTED,
        MAX_SUPPORTED_PROTOCOL,
        SIGNAL_CONNECTED,
        SIGNAL_NEW_ACCESSORY,
    )

    def _make_client():
        hass = MagicMock()
        fired = []
        hass.bus.async_fire = lambda event, data=None: fired.append((event, data))
        entry = SimpleNamespace(
            entry_id="E1",
            data={"host": "h", "port": 8765, "bearer_token": "tok"},
        )
        # Patch session creation away — _handle_message doesn't need it.
        client = LockBridgeClient.__new__(LockBridgeClient)
        client.hass = hass
        client.entry = entry
        client.states = {}
        client.connected = False
        client.protocol = None
        client.auth_failed = False
        client._on_auth_failed = None
        client._session_snapshot_seen = False
        return client, hass, fired

    def test_write_reverted_fires_event():
        client, _hass, fired = _make_client()
        client._handle_message(
            {
                "type": "write_reverted",
                "id": "lock1",
                "target": "secured",
                "reason": "budget_exhausted",
                "accessory_name": "Front Door",
            }
        )
        assert any(ev == EVENT_WRITE_REVERTED for ev, _ in fired)
        _, data = next(p for p in fired if p[0] == EVENT_WRITE_REVERTED)
        assert data["id"] == "lock1"
        assert data["reason"] == "budget_exhausted"
        assert data["entry_id"] == "E1"

    def test_unknown_message_type_ignored():
        client, _hass, fired = _make_client()
        # Must not raise and must not fire any event.
        client._handle_message({"type": "totally_new_envelope", "x": 1})
        assert fired == []

    def test_protocol_absent_assumes_one():
        client, _hass, _fired = _make_client()
        client._handle_message({"type": "hello"})
        assert client.protocol == 1

    def test_protocol_higher_keeps_working(caplog):
        client, _hass, _fired = _make_client()
        # A bridge newer than us must NOT hard-gate; we just record + warn.
        client._handle_message({"type": "hello", "protocol": MAX_SUPPORTED_PROTOCOL + 5})
        assert client.protocol == MAX_SUPPORTED_PROTOCOL + 5

    def test_snapshot_gates_connected_until_first_snapshot():
        client, hass, _fired = _make_client()
        sent = []
        import custom_components.ha_lockbridge.client as cmod

        orig = cmod.async_dispatcher_send
        cmod.async_dispatcher_send = lambda h, sig, *a: sent.append(sig)
        try:
            client._handle_message({"type": "snapshot", "accessories": [{"id": "a"}]})
        finally:
            cmod.async_dispatcher_send = orig
        connected = SIGNAL_CONNECTED.format(entry_id="E1")
        new_acc = SIGNAL_NEW_ACCESSORY.format(entry_id="E1")
        assert connected in sent
        assert new_acc in sent
