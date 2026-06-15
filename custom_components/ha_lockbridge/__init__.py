"""HA-LockBridge integration."""

from __future__ import annotations

import logging

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed, ConfigEntryNotReady
from homeassistant.helpers import device_registry as dr

from .const import DOMAIN, PLATFORMS
from .client import LockBridgeClient

_LOGGER = logging.getLogger(__name__)


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up a HA-LockBridge entry."""
    client = LockBridgeClient(hass, entry)
    try:
        await client.async_initial_snapshot()
    except PermissionError as err:
        # 401: the stored token is stale/revoked. Start the reauth flow rather
        # than retrying forever with a token the bridge will keep rejecting.
        raise ConfigEntryAuthFailed(
            "The bridge rejected the stored access token; re-pairing required."
        ) from err
    except Exception as err:  # noqa: BLE001
        # Bridge unreachable (Mac asleep/offline, network down). Raise
        # ConfigEntryNotReady so HA retries setup with backoff instead of
        # silently leaving the entry with zero entities until a manual reload.
        # Log type only — never the raw exception (it can embed request URLs).
        _LOGGER.debug("Initial snapshot failed (%s); will retry", type(err).__name__)
        raise ConfigEntryNotReady(
            "Could not reach the HA-LockBridge for the initial snapshot."
        ) from err

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

    # If the WS handshake later gets a 401 (token revoked while running), start
    # the reauth flow. Scheduling via async_create_task keeps this off the WS
    # loop's thread of control.
    def _start_reauth() -> None:
        _LOGGER.debug("Bridge rejected WS token; starting reauth")
        entry.async_start_reauth(hass)

    client.register_auth_failed_callback(_start_reauth)

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
