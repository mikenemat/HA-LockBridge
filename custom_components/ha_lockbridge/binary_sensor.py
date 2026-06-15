"""Low-battery + jammed binary sensors for each lock, plus a bridge-health
sensor on the hub device."""

from __future__ import annotations

from typing import Any

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity import Entity
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .client import LockBridgeClient
from .const import (
    DOMAIN,
    SIGNAL_CONNECTED,
    SIGNAL_DISCONNECTED,
    SIGNAL_NEW_ACCESSORY,
    SIGNAL_STATE_UPDATE,
)
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
    # A lock gets a jammed sensor unconditionally; the low-battery sensor only
    # once low_battery data exists. Track each independently so we never add a
    # duplicate when the same id is announced again.
    jammed_created: set[str] = set()
    low_batt_created: set[str] = set()
    # One "bridge online" sensor on the hub device — the single entity to alert
    # on for "bridge down".
    entities: list[Entity] = [BridgeHealthBinarySensor(client, entry)]
    for acc in enabled_accessories(client, entry):
        jammed_created.add(acc["id"])
        entities.append(JammedBinarySensor(client, entry, acc))
        if acc.get("low_battery") is not None:
            low_batt_created.add(acc["id"])
            entities.append(LowBatteryBinarySensor(client, entry, acc))
    async_add_entities(entities)

    @callback
    def _maybe_add(acc: dict[str, Any]) -> None:
        aid = acc.get("id")
        if not aid or not is_accessory_enabled(entry, aid):
            return
        new: list[LockBridgeBaseEntity] = []
        if aid not in jammed_created:
            jammed_created.add(aid)
            new.append(JammedBinarySensor(client, entry, acc))
        if aid not in low_batt_created and acc.get("low_battery") is not None:
            low_batt_created.add(aid)
            new.append(LowBatteryBinarySensor(client, entry, acc))
        if new:
            async_add_entities(new)

    register_dynamic_adder(
        hass, entry, SIGNAL_NEW_ACCESSORY, _maybe_add, async_dispatcher_connect
    )
    register_dynamic_adder(
        hass, entry, SIGNAL_STATE_UPDATE, _maybe_add, async_dispatcher_connect
    )


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


class BridgeHealthBinarySensor(BinarySensorEntity):
    """Connectivity sensor on the hub device: on == the WS link to the bridge
    is up. This is the one entity a user can alert on for "bridge down".

    Driven purely by `client.connected`, which is universally available on
    every bridge version (it reflects WS connected state, not any new wire
    field), so it works against old bridges too.
    """

    _attr_should_poll = False
    _attr_has_entity_name = True
    _attr_device_class = BinarySensorDeviceClass.CONNECTIVITY
    _attr_entity_category = EntityCategory.DIAGNOSTIC
    _attr_translation_key = "bridge_online"

    def __init__(self, client: LockBridgeClient, entry: ConfigEntry) -> None:
        self._client = client
        self._entry = entry

    @property
    def unique_id(self) -> str:
        return f"{self._entry.entry_id}_bridge_online"

    @property
    def name(self) -> str:
        return "Bridge online"

    @property
    def available(self) -> bool:
        # Always available: its whole job is to report up/down, so it must never
        # itself go unavailable when the bridge drops.
        return True

    @property
    def is_on(self) -> bool:
        return bool(self._client.connected)

    @property
    def device_info(self) -> DeviceInfo:
        # Attach to the hub device created in __init__.py.
        return DeviceInfo(identifiers={(DOMAIN, self._entry.entry_id)})

    async def async_added_to_hass(self) -> None:
        signal_connected = SIGNAL_CONNECTED.format(entry_id=self._entry.entry_id)
        signal_disconnected = SIGNAL_DISCONNECTED.format(entry_id=self._entry.entry_id)
        self.async_on_remove(
            async_dispatcher_connect(self.hass, signal_connected, self._on_change)
        )
        self.async_on_remove(
            async_dispatcher_connect(self.hass, signal_disconnected, self._on_change)
        )

    @callback
    def _on_change(self, *args: Any) -> None:
        self.async_write_ha_state()
