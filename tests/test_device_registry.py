"""Device-registry regression tests — these need the Home Assistant test rig.

They set the integration up inside a real (test) Home Assistant core against a
faked bridge client, so they catch what the source-extraction tests in
test_partition.py cannot: how core reacts to the `device_info` our entities
hand it.

Why they exist: lock devices used to link to the bridge ("hub") device with
`DeviceInfo(via_device=...)`. Home Assistant deprecated that parameter in favour
of `via_device_id`. At startup core only logged the deprecation, but when a user
renamed an entity ID in the UI core removed the entity and added it again from
its own `config` integration, the deprecation report was attributed to core,
raised `RuntimeError`, and the entity (a door lock!) was left without any state
until the integration was reloaded.

Requires a Home Assistant test rig, and the whole module is skipped without
one (importing it under a bare interpreter must not raise — same contract as
test_integration.py). Either rig works:

- `pytest-homeassistant` — Home Assistant's own package, for HA 2026.11 and
  newer. Install the release matching the HA version under test.
- `pytest-homeassistant-custom-component` — its predecessor, for older HA
  (0.13.354 pins HA 2026.8.0, the oldest version `hacs.json` allows).

The pytest options both rigs need (`asyncio_mode = auto`, ...) are in pytest.ini.
"""
from __future__ import annotations

import importlib
import importlib.util

_RIG = next(
    (
        name
        for name in ("pytest_homeassistant", "pytest_homeassistant_custom_component")
        if importlib.util.find_spec(name) is not None
    ),
    None,
)

if _RIG is None:  # pragma: no cover - exercised only without a rig
    try:
        import pytest

        pytestmark = pytest.mark.skip(
            reason="Home Assistant test rig not installed (pytest-homeassistant)"
        )
    except ModuleNotFoundError:
        pass
else:  # pragma: no cover - exercised only with a rig installed
    from unittest.mock import patch

    import pytest
    from homeassistant.components.config import (
        entity_registry as config_entity_registry,
    )
    from homeassistant.helpers import device_registry as dr
    from homeassistant.helpers import entity_platform
    from homeassistant.helpers import entity_registry as er
    from homeassistant.helpers import frame
    from homeassistant.helpers.dispatcher import async_dispatcher_send

    from custom_components.ha_lockbridge.client import LockBridgeClient
    from custom_components.ha_lockbridge.const import DOMAIN, SIGNAL_NEW_ACCESSORY

    MockConfigEntry = importlib.import_module(f"{_RIG}.common").MockConfigEntry

    ENTRY_ID = "bridge-entry"
    LOCK_ID = "lock-1"
    ACCESSORY = {
        "id": LOCK_ID,
        "name": "Front Door",
        "manufacturer": "Acme",
        "model": "Bolt",
        "firmware_version": "1.2.3",
        "reachable": True,
        "lifecycle_state": "locked",
        "battery_level": 87,
        "low_battery": False,
    }
    # One of the lock's entities per platform: domain -> the unique_id the
    # integration assigns it.
    LOCK_ENTITIES = {
        "lock": f"{LOCK_ID}_lock",
        "sensor": f"{LOCK_ID}_battery",
        "binary_sensor": f"{LOCK_ID}_jammed",
    }
    # The bridge-online sensor, which lives on the hub device itself.
    BRIDGE_ONLINE = ("binary_sensor", f"{ENTRY_ID}_bridge_online")

    @pytest.fixture(autouse=True)
    def _enable_custom_integrations(enable_custom_integrations):
        """Let the test core load integrations from custom_components/."""

    @pytest.fixture(autouse=True)
    def _fresh_usage_reports():
        """Forget which usage reports were already logged.

        Core logs each integration usage report only once per process, so
        without this the "no deprecation report" assertion could pass merely
        because an earlier test already triggered (and consumed) the report.
        """
        reported = getattr(frame, "_REPORTED_INTEGRATIONS", None)
        if reported is not None:
            reported.clear()

    @pytest.fixture
    async def entry(hass):
        """A loaded config entry talking to a faked bridge with one lock."""
        config_entry = MockConfigEntry(
            domain=DOMAIN,
            entry_id=ENTRY_ID,
            title="HA-LockBridge",
            unique_id="bridge-uuid",
            data={"host": "bridge.local", "port": 8765, "bearer_token": "tok"},
        )
        config_entry.add_to_hass(hass)

        async def _snapshot(self):
            self.states[LOCK_ID] = dict(ACCESSORY)
            return [self.states[LOCK_ID]]

        def _start_ws_loop(self):
            # No bridge to talk to: report the link as up straight away, the
            # way the real loop does after the first snapshot of a session.
            self.connected = True
            self._mark_session_connected()

        with (
            patch.object(LockBridgeClient, "async_initial_snapshot", _snapshot),
            patch.object(LockBridgeClient, "start_ws_loop", _start_ws_loop),
        ):
            assert await hass.config_entries.async_setup(config_entry.entry_id)
            await hass.async_block_till_done()
            yield config_entry

    def _entity_id(hass, domain: str, unique_id: str) -> str:
        entity_id = er.async_get(hass).async_get_entity_id(domain, DOMAIN, unique_id)
        assert entity_id is not None, f"no {domain} entity registered for {unique_id}"
        return entity_id

    def _device(hass, identifier: str):
        device = dr.async_get(hass).async_get_device_by_identifier(
            (DOMAIN, identifier), ENTRY_ID
        )
        assert device is not None, f"no device registered for {identifier}"
        return device

    def _lock_entities(hass, config_entry):
        """The live per-lock entity objects of every platform."""
        return [
            entity
            for platform in entity_platform.async_get_platforms(hass, DOMAIN)
            if platform.config_entry is config_entry
            for entity in platform.entities.values()
            if getattr(entity, "_accessory_id", None) == LOCK_ID
        ]

    async def test_entities_added_without_via_device_report(hass, entry, caplog):
        """Lock, sensor and binary_sensor load, linked to the hub, with no report."""
        for domain, unique_id in LOCK_ENTITIES.items():
            state = hass.states.get(_entity_id(hass, domain, unique_id))
            assert state is not None, f"{domain} entity has no state"
            assert state.state != "unavailable"

        # The deprecated parameter is gone from what we hand to core ...
        entities = _lock_entities(hass, entry)
        assert {entity.platform.domain for entity in entities} == set(LOCK_ENTITIES)
        hub = _device(hass, ENTRY_ID)
        for entity in entities:
            assert "via_device" not in entity.device_info
            assert entity.device_info["via_device_id"] == hub.id

        # ... so core has nothing to report, and the hub link is still made.
        assert "via_device" not in caplog.text
        assert _device(hass, LOCK_ID).via_device_id == hub.id

    @pytest.mark.parametrize(
        ("domain", "unique_id"),
        [*LOCK_ENTITIES.items(), BRIDGE_ONLINE],
        ids=["lock", "battery", "jammed", "bridge_online"],
    )
    async def test_entity_id_rename_keeps_entity_alive(
        hass, hass_ws_client, entry, caplog, domain, unique_id
    ):
        """Renaming an entity ID in the UI must leave the entity with a state.

        Goes through the same websocket command the frontend uses, because the
        original failure depended on core re-adding the entity from inside its
        own `config` integration.
        """
        config_entity_registry.async_setup(hass)
        ws = await hass_ws_client(hass)

        old_entity_id = _entity_id(hass, domain, unique_id)
        before = hass.states.get(old_entity_id)
        assert before is not None
        new_entity_id = f"{domain}.renamed_by_the_user"

        await ws.send_json(
            {
                "id": 1,
                "type": "config/entity_registry/update",
                "entity_id": old_entity_id,
                "new_entity_id": new_entity_id,
            }
        )
        response = await ws.receive_json()
        assert response["success"], response
        await hass.async_block_till_done()

        assert _entity_id(hass, domain, unique_id) == new_entity_id
        assert hass.states.get(old_entity_id) is None
        after = hass.states.get(new_entity_id)
        assert after is not None, "entity vanished from the state machine"
        assert after.state == before.state
        assert "Error adding entity" not in caplog.text
        assert "via_device" not in caplog.text

    async def test_missing_hub_device_never_blocks_a_lock(hass, entry, caplog):
        """The hub link is display-only: without a hub device locks still load."""
        dr.async_get(hass).async_remove_device(_device(hass, ENTRY_ID).id)
        await hass.async_block_till_done()

        late = {**ACCESSORY, "id": "lock-2", "name": "Back Door"}
        hass.data[DOMAIN][entry.entry_id].states["lock-2"] = late
        async_dispatcher_send(
            hass, SIGNAL_NEW_ACCESSORY.format(entry_id=entry.entry_id), late
        )
        await hass.async_block_till_done()

        state = hass.states.get(_entity_id(hass, "lock", "lock-2_lock"))
        assert state is not None, "lock added after hub removal has no state"
        assert _device(hass, "lock-2").via_device_id is None
        assert "Error adding entity" not in caplog.text
