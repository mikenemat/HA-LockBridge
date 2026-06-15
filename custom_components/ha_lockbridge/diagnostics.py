"""Diagnostics support for HA-LockBridge.

HomeAssistant calls this via the "Download Diagnostics" button on the
integration's settings page. We return enough info to debug bridge↔HA issues
without leaking bearer tokens or other secrets.
"""

from __future__ import annotations

from typing import Any

import aiohttp
from homeassistant.components.diagnostics import async_redact_data
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .client import LockBridgeClient
from .const import CONF_HOST, CONF_PORT, CONF_TOKEN, DOMAIN, HTTP_TIMEOUT

TO_REDACT = {CONF_TOKEN}


async def async_get_config_entry_diagnostics(
    hass: HomeAssistant, entry: ConfigEntry
) -> dict[str, Any]:
    """Return diagnostics for a config entry."""
    client: LockBridgeClient | None = hass.data.get(DOMAIN, {}).get(entry.entry_id)

    # Best-effort live fetch of /info (no auth needed) to see what the bridge
    # currently reports — useful when entry.data is stale or wrong.
    bridge_info: dict[str, Any] = {}
    bridge_health: dict[str, Any] = {}
    session = async_get_clientsession(hass)
    host = entry.data[CONF_HOST]
    port = entry.data[CONF_PORT]
    try:
        async with session.get(
            f"http://{host}:{port}/info",
            timeout=aiohttp.ClientTimeout(total=HTTP_TIMEOUT),
        ) as resp:
            bridge_info = {
                "status": resp.status,
                "body": await resp.json() if resp.status == 200 else await resp.text(),
            }
    except Exception as err:  # noqa: BLE001
        bridge_info = {"error": type(err).__name__}

    # /health is also unauthenticated. Newer bridges may add an optional
    # `homes_visible` bool; surface it IF present (never required).
    try:
        async with session.get(
            f"http://{host}:{port}/health",
            timeout=aiohttp.ClientTimeout(total=HTTP_TIMEOUT),
        ) as resp:
            if resp.status == 200:
                body = await resp.json()
                bridge_health = {"status": resp.status}
                if isinstance(body, dict) and "homes_visible" in body:
                    bridge_health["homes_visible"] = body.get("homes_visible")
            else:
                bridge_health = {"status": resp.status}
    except Exception as err:  # noqa: BLE001
        bridge_health = {"error": type(err).__name__}

    states_snapshot: list[dict[str, Any]] = []
    if client is not None:
        # Strip any potentially sensitive bits per-accessory. None today, but
        # leaves a hook for the future.
        for acc in client.states.values():
            states_snapshot.append(
                {
                    "id": acc.get("id"),
                    "name": acc.get("name"),
                    "manufacturer": acc.get("manufacturer"),
                    "model": acc.get("model"),
                    "firmware_version": acc.get("firmware_version"),
                    "reachable": acc.get("reachable"),
                    "current_state": acc.get("current_state"),
                    "target_state": acc.get("target_state"),
                    "lifecycle_state": acc.get("lifecycle_state"),
                    "battery_level": acc.get("battery_level"),
                    "low_battery": acc.get("low_battery"),
                    "updated_at": acc.get("updated_at"),
                }
            )

    return {
        "entry": {
            "data": async_redact_data(dict(entry.data), TO_REDACT),
            "options": dict(entry.options),
        },
        "client": {
            "exists": client is not None,
            "connected": bool(client and client.connected),
            "accessory_count": len(client.states) if client else 0,
            # Protocol the bridge advertised (None => not yet seen / old bridge).
            "protocol": getattr(client, "protocol", None) if client else None,
            "auth_failed": bool(client and getattr(client, "auth_failed", False)),
        },
        "bridge_info": bridge_info,
        "bridge_health": bridge_health,
        "accessories": states_snapshot,
    }
