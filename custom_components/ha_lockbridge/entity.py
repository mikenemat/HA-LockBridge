"""Base entity for HA-LockBridge — wires up the dispatcher plumbing."""

from __future__ import annotations

from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity import Entity

from .client import LockBridgeClient
from .const import (
    CONF_ENABLED_IDS,
    DOMAIN,
    SIGNAL_CONNECTED,
    SIGNAL_DISCONNECTED,
    SIGNAL_REMOVED,
    SIGNAL_STATE_UPDATE,
)


def enabled_accessories(
    client: LockBridgeClient, entry: ConfigEntry
) -> list[dict[str, Any]]:
    """Return only the accessories the user chose to expose.

    If the entry has no `enabled_accessory_ids` in options (pre-options-flow
    entries), fall back to returning everything — so upgrading a working
    install doesn't silently drop entities.
    """
    enabled = entry.options.get(CONF_ENABLED_IDS)
    if not enabled:
        return list(client.states.values())
    enabled_set = set(enabled)
    return [a for a in client.states.values() if a.get("id") in enabled_set]


class LockBridgeBaseEntity(Entity):
    """Shared base for all per-accessory entities."""

    _attr_should_poll = False
    _attr_has_entity_name = True

    def __init__(
        self,
        client: LockBridgeClient,
        entry: ConfigEntry,
        accessory: dict[str, Any],
    ) -> None:
        self._client = client
        self._entry = entry
        self._accessory_id: str = accessory["id"]
        self._state: dict[str, Any] = accessory

    @property
    def accessory(self) -> dict[str, Any]:
        """Always read from the client's live state dict."""
        return self._client.states.get(self._accessory_id, self._state)

    @property
    def device_info(self) -> DeviceInfo:
        acc = self.accessory
        manufacturer = acc.get("manufacturer") or "Unknown"
        model = acc.get("model") or "Unknown"
        sw_version = acc.get("firmware_version")
        return DeviceInfo(
            identifiers={(DOMAIN, self._accessory_id)},
            name=acc.get("name") or "Lock",
            manufacturer=manufacturer,
            model=model,
            sw_version=sw_version,
            via_device=(DOMAIN, self._entry.entry_id),
        )

    @property
    def available(self) -> bool:
        return bool(self._client.connected) and bool(self.accessory.get("reachable"))

    async def async_added_to_hass(self) -> None:
        signal_state = SIGNAL_STATE_UPDATE.format(entry_id=self._entry.entry_id)
        signal_removed = SIGNAL_REMOVED.format(entry_id=self._entry.entry_id)
        signal_connected = SIGNAL_CONNECTED.format(entry_id=self._entry.entry_id)
        signal_disconnected = SIGNAL_DISCONNECTED.format(entry_id=self._entry.entry_id)

        self.async_on_remove(
            async_dispatcher_connect(self.hass, signal_state, self._on_state)
        )
        self.async_on_remove(
            async_dispatcher_connect(self.hass, signal_removed, self._on_removed)
        )
        self.async_on_remove(
            async_dispatcher_connect(self.hass, signal_connected, self._on_conn_change)
        )
        self.async_on_remove(
            async_dispatcher_connect(self.hass, signal_disconnected, self._on_conn_change)
        )

    @callback
    def _on_state(self, accessory: dict[str, Any]) -> None:
        if accessory.get("id") != self._accessory_id:
            return
        self._state = accessory
        self.async_write_ha_state()

    @callback
    def _on_removed(self, accessory_id: str) -> None:
        if accessory_id != self._accessory_id:
            return
        self.async_write_ha_state()

    @callback
    def _on_conn_change(self) -> None:
        self.async_write_ha_state()
