"""Lock entity backed by the HA-LockBridge."""

from __future__ import annotations

import logging
from typing import Any

from homeassistant.components.lock import LockEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .client import LockBridgeClient
from .const import DOMAIN, SIGNAL_NEW_ACCESSORY
from .entity import (
    LockBridgeBaseEntity,
    enabled_accessories,
    is_accessory_enabled,
    register_dynamic_adder,
)

_LOGGER = logging.getLogger(__name__)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    client: LockBridgeClient = hass.data[DOMAIN][entry.entry_id]
    known: set[str] = set()
    entities = []
    for acc in enabled_accessories(client, entry):
        known.add(acc["id"])
        entities.append(HALockBridgeLock(client, entry, acc))
    async_add_entities(entities)

    @callback
    def _maybe_add(acc: dict[str, Any]) -> None:
        aid = acc.get("id")
        if not aid or aid in known:
            return
        if not is_accessory_enabled(entry, aid):
            return
        known.add(aid)
        async_add_entities([HALockBridgeLock(client, entry, acc)])

    register_dynamic_adder(
        hass, entry, SIGNAL_NEW_ACCESSORY, _maybe_add, async_dispatcher_connect
    )


class HALockBridgeLock(LockBridgeBaseEntity, LockEntity):
    """LockEntity that maps the bridge's lifecycle_state to HA's lock semantics."""

    _attr_translation_key = "lock"

    @property
    def unique_id(self) -> str:
        return f"{self._accessory_id}_lock"

    @property
    def name(self) -> str | None:
        # Use device-level name (set via device_info) so HA renders one row per lock.
        return None

    # --- state ---------------------------------------------------------------
    #
    # When the bridge can't determine the lock's state it reports
    # `lifecycle_state == "unknown"` (or omits it entirely on very old
    # snapshots). HA's LockEntity treats `is_locked == False` as the affirmative
    # "Unlocked" — which would silently render an *unknown* lock as unlocked and
    # feed that into automations. So we return None in that case, and HA shows
    # "Unknown". The four flags only ever return True for their own state.

    @property
    def is_locked(self) -> bool | None:
        lc = self._lifecycle()
        return None if lc == "unknown" else lc == "locked"

    @property
    def is_locking(self) -> bool | None:
        lc = self._lifecycle()
        return None if lc == "unknown" else lc == "locking"

    @property
    def is_unlocking(self) -> bool | None:
        lc = self._lifecycle()
        return None if lc == "unknown" else lc == "unlocking"

    @property
    def is_jammed(self) -> bool | None:
        lc = self._lifecycle()
        return None if lc == "unknown" else lc == "jammed"

    def _lifecycle(self) -> str:
        # Defensive: missing/None/empty all collapse to "unknown".
        return self.accessory.get("lifecycle_state") or "unknown"

    # --- commands ------------------------------------------------------------

    async def async_lock(self, **kwargs: Any) -> None:
        await self._set("secured")

    async def async_unlock(self, **kwargs: Any) -> None:
        await self._set("unsecured")

    async def _set(self, target: str) -> None:
        try:
            updated = await self._client.async_set_target(self._accessory_id, target)
        except PermissionError as err:
            # Token rejected — mark the client so a follow-up setup raises
            # ConfigEntryAuthFailed, and surface a clean toast (not a traceback).
            self._client.auth_failed = True
            raise HomeAssistantError(
                "The bridge rejected the access token. Re-pair the bridge "
                "(Settings → Devices & Services → reconfigure)."
            ) from err
        except LookupError as err:
            _LOGGER.error("Lock %s not found in bridge: %s", self._accessory_id, err)
            raise HomeAssistantError(
                "The bridge no longer knows about this lock."
            ) from err
        except ConnectionError as err:
            _LOGGER.warning("Lock %s unreachable: %s", self._accessory_id, err)
            raise HomeAssistantError(
                "The lock is currently unreachable from the bridge."
            ) from err
        except (TimeoutError, OSError) as err:
            # aiohttp client errors subclass OSError; never leak the raw URL.
            _LOGGER.warning(
                "Command to lock %s failed (%s)", self._accessory_id, type(err).__name__
            )
            raise HomeAssistantError(
                "Could not reach the bridge to send the command."
            ) from err
        # The WS push will deliver the canonical state shortly. We optimistically
        # update our local copy so the UI flips immediately instead of waiting
        # for the round-trip.
        self._state = updated
        self.async_write_ha_state()
