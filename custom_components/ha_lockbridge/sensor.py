"""Battery-level sensor for each lock."""

from __future__ import annotations

from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import PERCENTAGE, EntityCategory
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .client import LockBridgeClient
from .const import DOMAIN, SIGNAL_NEW_ACCESSORY, SIGNAL_STATE_UPDATE
from .entity import (
    LockBridgeBaseEntity,
    enabled_accessories,
    is_accessory_enabled,
    register_dynamic_adder,
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    client: LockBridgeClient = hass.data[DOMAIN][entry.entry_id]
    # Track which accessory ids already have a battery sensor so late-arriving
    # battery data (and locks added mid-run) get one exactly once.
    created: set[str] = set()
    entities = []
    for acc in enabled_accessories(client, entry):
        # Only add the battery sensor when the bridge actually reports a level —
        # some locks don't expose it.
        if acc.get("battery_level") is not None:
            created.add(acc["id"])
            entities.append(BatterySensor(client, entry, acc))
    async_add_entities(entities)

    @callback
    def _maybe_add(acc: dict[str, Any]) -> None:
        aid = acc.get("id")
        if not aid or aid in created:
            return
        if not is_accessory_enabled(entry, aid):
            return
        if acc.get("battery_level") is None:
            return
        created.add(aid)
        async_add_entities([BatterySensor(client, entry, acc)])

    # Both "new accessory id" and "state update" can be the first time battery
    # data shows up for an already-known lock, so listen to both.
    register_dynamic_adder(
        hass, entry, SIGNAL_NEW_ACCESSORY, _maybe_add, async_dispatcher_connect
    )
    register_dynamic_adder(
        hass, entry, SIGNAL_STATE_UPDATE, _maybe_add, async_dispatcher_connect
    )


class BatterySensor(LockBridgeBaseEntity, SensorEntity):
    _attr_device_class = SensorDeviceClass.BATTERY
    _attr_state_class = SensorStateClass.MEASUREMENT
    _attr_native_unit_of_measurement = PERCENTAGE
    _attr_entity_category = EntityCategory.DIAGNOSTIC
    _attr_translation_key = "battery"

    @property
    def unique_id(self) -> str:
        return f"{self._accessory_id}_battery"

    @property
    def name(self) -> str:
        return "Battery"

    @property
    def native_value(self) -> int | None:
        return self.accessory.get("battery_level")
