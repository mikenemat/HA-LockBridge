"""Battery-level sensor for each lock."""

from __future__ import annotations

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import PERCENTAGE, EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .client import LockBridgeClient
from .const import DOMAIN
from .entity import LockBridgeBaseEntity, enabled_accessories


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    client: LockBridgeClient = hass.data[DOMAIN][entry.entry_id]
    entities = []
    for acc in enabled_accessories(client, entry):
        # Only add the battery sensor when the bridge actually reports a level —
        # some locks don't expose it.
        if acc.get("battery_level") is not None:
            entities.append(BatterySensor(client, entry, acc))
    async_add_entities(entities)


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
