"""HA-LockBridge integration."""

from __future__ import annotations

import logging

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers import device_registry as dr

from .const import DOMAIN, PLATFORMS
from .client import LockBridgeClient

_LOGGER = logging.getLogger(__name__)


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up a HA-LockBridge entry."""
    client = LockBridgeClient(hass, entry)
    try:
        await client.async_initial_snapshot()
    except Exception as err:  # noqa: BLE001
        _LOGGER.error("Failed initial snapshot from bridge: %s", err)
        # We still proceed — the client will keep retrying. Entities will be
        # unavailable until the bridge is reachable.

    # Register the bridge itself as a "hub" device. Lock entities reference
    # this device via `via_device` so HA's UI can group them under their hub.
    # Without it, HA logs a deprecation warning on every entity creation.
    device_registry = dr.async_get(hass)
    device_registry.async_get_or_create(
        config_entry_id=entry.entry_id,
        identifiers={(DOMAIN, entry.entry_id)},
        name="HA-LockBridge",
        manufacturer="HA-LockBridge",
        model="Bridge",
        entry_type=dr.DeviceEntryType.SERVICE,
    )

    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = client

    # Set up platforms FIRST so entities subscribe to dispatcher signals
    # (SIGNAL_CONNECTED / SIGNAL_STATE_UPDATE) before the WS loop has a
    # chance to fire them. Without this ordering, the first WS connect's
    # SIGNAL_CONNECTED can be dispatched to zero listeners and entities
    # stay stuck reporting available=False.
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    client.start_ws_loop()

    entry.async_on_unload(entry.add_update_listener(_async_update_listener))
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Unload a config entry."""
    unload_ok = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unload_ok:
        client: LockBridgeClient = hass.data[DOMAIN].pop(entry.entry_id)
        await client.async_shutdown()
    return unload_ok


async def _async_update_listener(hass: HomeAssistant, entry: ConfigEntry) -> None:
    """Reload entry when options change (e.g. host/port/token edits)."""
    await hass.config_entries.async_reload(entry.entry_id)
