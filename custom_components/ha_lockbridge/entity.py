"""Base entity for HA-LockBridge — wires up the dispatcher plumbing."""

from __future__ import annotations

from typing import Any, Callable

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
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

# Sentinel telling enabled_accessory_ids apart: a *missing* key (pre-options-flow
# entries, or entries created before per-device selection existed) means "expose
# everything". An explicit empty list means "the user deselected everything" and
# we must expose nothing. `None` from .get() can't distinguish these on its own,
# so we probe membership explicitly below.


def is_accessory_enabled(entry: ConfigEntry, accessory_id: str) -> bool:
    """Whether a single accessory id should be exposed for this entry.

    - Key absent from options  -> expose everything (legacy/upgrade safety).
    - Key present, empty list   -> expose nothing.
    - Key present, non-empty    -> expose only listed ids.
    """
    if CONF_ENABLED_IDS not in entry.options:
        return True
    return accessory_id in set(entry.options.get(CONF_ENABLED_IDS) or [])


def enabled_accessories(
    client: LockBridgeClient, entry: ConfigEntry
) -> list[dict[str, Any]]:
    """Return only the accessories the user chose to expose.

    Distinguishes *unset* from *empty*:
    - If the entry has no `enabled_accessory_ids` key in options (pre-options-flow
      entries), return everything — so upgrading a working install doesn't
      silently drop entities.
    - If the key is present but an empty list, the user deliberately deselected
      everything: return nothing (the old `if not enabled` collapsed these two
      and exposed everything when the user wanted nothing).
    """
    if CONF_ENABLED_IDS not in entry.options:
        return list(client.states.values())
    enabled_set = set(entry.options.get(CONF_ENABLED_IDS) or [])
    return [a for a in client.states.values() if a.get("id") in enabled_set]


def register_dynamic_adder(
    hass: HomeAssistant,
    entry: ConfigEntry,
    signal_template: str,
    handler: Callable[[dict[str, Any]], None],
    connect: Callable[..., Callable[[], None]] = async_dispatcher_connect,
) -> None:
    """Subscribe `handler` to a per-entry dispatcher signal and ensure the
    subscription is torn down on entry unload.

    `connect` is injectable for testing; defaults to HA's dispatcher connect.
    """
    signal = signal_template.format(entry_id=entry.entry_id)
    entry.async_on_unload(connect(hass, signal, handler))


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
        # Set when the bridge tells us this accessory was removed. We then report
        # unavailable instead of freezing the last-known state as "available".
        self._removed: bool = False

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
        base_name = acc.get("name") or "Lock"
        # Prefix the HomeKit home name when the bridge supplies one (it only does
        # so for multi-home setups). Display-only: the device/entity identity is
        # keyed on the wire id (`identifiers` / `unique_id`), never the name, so
        # this only relabels an existing device — it never re-creates it, and
        # the entity_id stays put. Falls back to the bare name for old bridges
        # that don't send `home`.
        home = acc.get("home")
        display_name = f"{home} {base_name}" if home else base_name
        return DeviceInfo(
            identifiers={(DOMAIN, self._accessory_id)},
            name=display_name,
            manufacturer=manufacturer,
            model=model,
            sw_version=sw_version,
            via_device=(DOMAIN, self._entry.entry_id),
        )

    @property
    def available(self) -> bool:
        if self._removed:
            return False
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
        # A state update means the accessory is back / still present — clear the
        # removed flag so it can recover from a transient removal.
        self._removed = False
        self._state = accessory
        self.async_write_ha_state()

    @callback
    def _on_removed(self, accessory_id: str) -> None:
        if accessory_id != self._accessory_id:
            return
        # Mark unavailable rather than freezing the last-known state as
        # "available" forever.
        self._removed = True
        self.async_write_ha_state()

    @callback
    def _on_conn_change(self) -> None:
        self.async_write_ha_state()
