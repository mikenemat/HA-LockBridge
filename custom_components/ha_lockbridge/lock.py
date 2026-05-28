"""Lock entity backed by the HA-LockBridge."""

from __future__ import annotations

import logging
from typing import Any

from homeassistant.components.lock import LockEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .client import LockBridgeClient
from .const import DOMAIN
from .entity import LockBridgeBaseEntity, enabled_accessories

_LOGGER = logging.getLogger(__name__)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    client: LockBridgeClient = hass.data[DOMAIN][entry.entry_id]
    entities = [
        HALockBridgeLock(client, entry, acc)
        for acc in enabled_accessories(client, entry)
    ]
    async_add_entities(entities)


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

    @property
    def is_locked(self) -> bool | None:
        return self._lifecycle() == "locked"

    @property
    def is_locking(self) -> bool | None:
        return self._lifecycle() == "locking"

    @property
    def is_unlocking(self) -> bool | None:
        return self._lifecycle() == "unlocking"

    @property
    def is_jammed(self) -> bool | None:
        return self._lifecycle() == "jammed"

    def _lifecycle(self) -> str:
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
            raise PermissionError(f"Bridge rejected token: {err}") from err
        except LookupError as err:
            _LOGGER.error("Lock %s not found in bridge: %s", self._accessory_id, err)
            raise
        except ConnectionError as err:
            _LOGGER.warning("Lock %s unreachable: %s", self._accessory_id, err)
            raise
        # The WS push will deliver the canonical state shortly. We optimistically
        # update our local copy so the UI flips immediately instead of waiting
        # for the round-trip.
        self._state = updated
        self.async_write_ha_state()
