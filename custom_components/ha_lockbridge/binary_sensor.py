"""Low-battery + jammed binary sensors for each lock."""

from __future__ import annotations

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory
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
        entities.append(JammedBinarySensor(client, entry, acc))
        if acc.get("low_battery") is not None:
            entities.append(LowBatteryBinarySensor(client, entry, acc))
    async_add_entities(entities)


class JammedBinarySensor(LockBridgeBaseEntity, BinarySensorEntity):
    _attr_device_class = BinarySensorDeviceClass.PROBLEM
    _attr_entity_category = EntityCategory.DIAGNOSTIC
    _attr_translation_key = "jammed"

    @property
    def unique_id(self) -> str:
        return f"{self._accessory_id}_jammed"

    @property
    def name(self) -> str:
        return "Jammed"

    @property
    def is_on(self) -> bool | None:
        return self.accessory.get("lifecycle_state") == "jammed"


class LowBatteryBinarySensor(LockBridgeBaseEntity, BinarySensorEntity):
    _attr_device_class = BinarySensorDeviceClass.BATTERY
    _attr_entity_category = EntityCategory.DIAGNOSTIC
    _attr_translation_key = "low_battery"

    @property
    def unique_id(self) -> str:
        return f"{self._accessory_id}_low_battery"

    @property
    def name(self) -> str:
        return "Low battery"

    @property
    def is_on(self) -> bool | None:
        return bool(self.accessory.get("low_battery"))
