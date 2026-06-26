"""Config + options flow for HA-LockBridge.

Setup paths:
- Zeroconf discovery (the primary, expected path): bridge announces via Bonjour,
  HA shows a discovered card → user clicks Configure → confirm pair → click
  Approve in the macOS notification on the bridge → done.
- Manual entry (fallback): user types host/port if discovery doesn't work for
  some reason (multicast blocked, etc.). Same pair flow follows.

Re-discovery: on every Bonjour announcement, async_step_zeroconf is called.
If the UUID already matches an existing entry, `_abort_if_unique_id_configured`
updates that entry's host/port (handles Mac renames, IP changes) and triggers
reload. The user never has to do anything.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import aiohttp
import voluptuous as vol
from homeassistant import config_entries
from homeassistant.components import zeroconf
from homeassistant.core import callback
from homeassistant.data_entry_flow import FlowResult
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .const import (
    CONF_ENABLED_IDS,
    CONF_HOST,
    CONF_PORT,
    CONF_TOKEN,
    DEFAULT_PORT,
    DOMAIN,
    HTTP_TIMEOUT,
    PAIR_INITIATE_TIMEOUT,
    PAIR_MAX_WAIT,
    PAIR_POLL_INTERVAL,
    THORBOLT_MANUFACTURER,
)

_LOGGER = logging.getLogger(__name__)


_MANUAL_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_HOST): str,
        vol.Required(CONF_PORT, default=DEFAULT_PORT): int,
    }
)


def _lock_options(
    accessories: list[dict[str, Any]],
) -> tuple[dict[str, str], list[str]]:
    """Build a single id → label map for one combined checkbox list, plus the
    list of ThorBolt ids (the recommended default selection).

    ThorBolt X1 locks are NOT split into a separate group/dropdown anymore — they
    sit in the same checkbox list as every other lock and are flagged inline with
    a "✅ <model> Verified" badge in the label. (Config-flow labels are plain
    text, so the ✅ emoji stands in for a green checkmark badge.) The bridge
    filters out unhealthy/ghost accessories before we get the list.
    """
    options: dict[str, str] = {}
    thorbolt_ids: list[str] = []
    # Sort by home then name so multi-home setups group together in the list.
    # The stable id is the final tiebreaker so ordering is a pure function of the
    # accessory SET, not the order the bridge happens to return them in: the
    # options flow re-fetches /accessories between the render and submit passes,
    # and without an id tiebreaker two byte-identical labels would tie on
    # (home, name) and fall back to the bridge's array order — which can differ
    # across the two fetches and would then mis-map which toggle controls which
    # lock once the duplicate-label "(n)" suffix is applied below.
    for acc in sorted(
        accessories,
        key=lambda a: (
            (a.get("home") or ""),
            (a.get("name") or "").lower(),
            a.get("id") or "",
        ),
    ):
        base = acc.get("name") or acc["id"]
        home = acc.get("home")
        label = f"{home} {base}" if home else base
        if acc.get("manufacturer") == THORBOLT_MANUFACTURER:
            thorbolt_ids.append(acc["id"])
            model = acc.get("model") or "ThorBolt X1"
            label = f"{label}  ✅ {model} Verified"
        else:
            model = acc.get("model")
            if model:
                label = f"{label}  ({model})"
        options[acc["id"]] = label
    return options, thorbolt_ids


def _checkbox_fields(
    options: dict[str, str], default_ids: list[str]
) -> tuple[vol.Schema, dict[str, str]]:
    """Build one always-visible toggle per lock, keyed by its display label, plus
    a {field_key -> accessory_id} map for decoding the submission.

    Why NOT a single `cv.multi_select`: Home Assistant's config-flow multi_select
    renders as a flat checkbox list only up to ~6 options and COLLAPSES INTO A
    DROPDOWN above that — which buried every lock. Individual boolean fields
    render as one labeled row each regardless of how many locks there are, so
    they all stay listed plainly on the page. The label (with the ✅ ThorBolt X1
    Verified badge) is used as the field key, since dynamic per-lock fields can't
    be pre-translated.
    """
    default_set = set(default_ids)
    schema_dict: dict[Any, Any] = {}
    key_to_id: dict[str, str] = {}
    for aid, label in options.items():
        key = label
        n = 2
        while key in key_to_id:  # guarantee unique field keys for duplicate labels
            key = f"{label} ({n})"
            n += 1
        key_to_id[key] = aid
        schema_dict[vol.Optional(key, default=(aid in default_set))] = bool
    return vol.Schema(schema_dict), key_to_id


async def _fetch_accessories(
    hass, host: str, port: int, token: str
) -> list[dict[str, Any]] | None:
    session = async_get_clientsession(hass)
    timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
    try:
        async with session.get(
            f"http://{host}:{port}/accessories",
            headers={"Authorization": f"Bearer {token}"},
            timeout=timeout,
        ) as resp:
            if resp.status != 200:
                return None
            data = await resp.json()
            return data.get("accessories", [])
    except (aiohttp.ClientError, TimeoutError):
        return None


async def _fetch_info(hass, host: str, port: int) -> dict[str, Any] | None:
    """Read /info to get instance_id without auth."""
    session = async_get_clientsession(hass)
    timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
    try:
        async with session.get(f"http://{host}:{port}/info", timeout=timeout) as resp:
            if resp.status != 200:
                return None
            return await resp.json()
    except (aiohttp.ClientError, TimeoutError):
        return None


class HALockBridgeConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Discovery + pair flow."""

    VERSION = 1

    def __init__(self) -> None:
        self._host: str | None = None
        self._port: int | None = None
        self._instance_id: str | None = None
        self._token: str | None = None
        self._accessories: list[dict[str, Any]] = []
        self._pair_task: asyncio.Task | None = None
        # "approved" / "denied" / "expired" / "error" / "already_paired"
        self._pair_result: str | None = None
        # Set when we're re-authenticating an existing entry (token revoked /
        # bridge re-paired) rather than configuring a brand-new one.
        self._reauth_entry: config_entries.ConfigEntry | None = None

    # ---------------------------------------------------------------- discovery

    async def async_step_zeroconf(
        self, discovery_info: zeroconf.ZeroconfServiceInfo
    ) -> FlowResult:
        """Bridge discovered via Bonjour."""
        properties = discovery_info.properties or {}
        uuid = properties.get("uuid")
        if not uuid:
            return self.async_abort(reason="missing_uuid_txt")

        # Prefer the .local hostname over the IP — survives IP changes via mDNS.
        host = discovery_info.hostname or str(discovery_info.host)
        if host.endswith("."):
            host = host[:-1]
        port = discovery_info.port or DEFAULT_PORT

        await self.async_set_unique_id(uuid)
        # If this UUID already matches an existing entry, update its host/port
        # to the freshly-discovered values and reload. The user sees nothing.
        self._abort_if_unique_id_configured(
            updates={CONF_HOST: host, CONF_PORT: port}
        )

        self._host = host
        self._port = port
        self._instance_id = uuid

        # Friendly title on the discovered card
        self.context["title_placeholders"] = {
            "name": properties.get("name", "HA-LockBridge"),
            "host": host,
        }
        return await self.async_step_pair_confirm()

    # ---------------------------------------------------------------- manual

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        """Fallback: user enters host/port if discovery isn't working."""
        errors: dict[str, str] = {}
        if user_input is not None:
            host = user_input[CONF_HOST].strip()
            port = int(user_input[CONF_PORT])

            info = await _fetch_info(self.hass, host, port)
            if info is None:
                errors["base"] = "cannot_connect"
            else:
                uuid = info.get("instance_id")
                if not uuid:
                    errors["base"] = "cannot_connect"
                else:
                    await self.async_set_unique_id(uuid)
                    self._abort_if_unique_id_configured(
                        updates={CONF_HOST: host, CONF_PORT: port}
                    )
                    self._host = host
                    self._port = port
                    self._instance_id = uuid
                    return await self.async_step_pair_confirm()

        return self.async_show_form(
            step_id="user",
            data_schema=_MANUAL_SCHEMA,
            errors=errors,
        )

    # ---------------------------------------------------------------- reauth

    async def async_step_reauth(
        self, entry_data: dict[str, Any]
    ) -> FlowResult:
        """Entry point when HA detects the stored token is no longer valid
        (401 on setup or WS handshake). We re-run the same approve-on-the-bridge
        pair flow and update CONF_TOKEN in place."""
        self._reauth_entry = self.hass.config_entries.async_get_entry(
            self.context["entry_id"]
        )
        if self._reauth_entry is not None:
            self._host = self._reauth_entry.data.get(CONF_HOST)
            self._port = self._reauth_entry.data.get(CONF_PORT)
            self._instance_id = self._reauth_entry.unique_id
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        """Confirm re-pair intent, then reuse the normal pair flow."""
        if user_input is not None:
            return await self.async_step_pair_in_progress()
        return self.async_show_form(
            step_id="reauth_confirm",
            data_schema=vol.Schema({}),
            description_placeholders={
                "host": self._host or "",
                "port": str(self._port or DEFAULT_PORT),
            },
        )

    # ---------------------------------------------------------------- pair

    async def async_step_pair_confirm(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        """User confirms intent to pair with the discovered bridge."""
        if user_input is not None:
            return await self.async_step_pair_in_progress()
        return self.async_show_form(
            step_id="pair_confirm",
            data_schema=vol.Schema({}),
            description_placeholders={
                "host": self._host or "",
                "port": str(self._port or DEFAULT_PORT),
            },
        )

    async def async_step_pair_in_progress(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        """Show spinner while the user clicks Approve on the bridge."""
        if self._pair_task is None:
            self._pair_task = self.hass.async_create_task(self._do_pair())

        if not self._pair_task.done():
            return self.async_show_progress(
                step_id="pair_in_progress",
                progress_action="awaiting_approval",
                progress_task=self._pair_task,
            )

        # Task completed — interpret result
        result = self._pair_result or "error"
        if result == "approved":
            if self._reauth_entry is not None:
                return self.async_show_progress_done(next_step_id="reauth_done")
            return self.async_show_progress_done(next_step_id="select_devices")
        if result == "already_paired":
            return self.async_show_progress_done(next_step_id="pair_already_paired")
        return self.async_show_progress_done(next_step_id=f"pair_{result}")

    async def async_step_reauth_done(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        """Write the freshly-minted token back onto the existing entry and
        reload it. No new entry, no re-selecting devices."""
        entry = self._reauth_entry
        if entry is None or not self._token:
            return self.async_abort(reason="cannot_connect")
        return self.async_update_reload_and_abort(
            entry,
            data={**entry.data, CONF_TOKEN: self._token},
            reason="reauth_successful",
        )

    async def async_step_pair_already_paired(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        return self.async_abort(reason="already_paired")

    async def _do_pair(self) -> None:
        """Initiate + poll. Sets self._pair_result and (on success) self._token + self._accessories."""
        session = async_get_clientsession(self.hass)
        base = f"http://{self._host}:{self._port}"
        client_name = (
            (self.hass.config.location_name or "Home Assistant")
            + f" ({self.hass.config.internal_url or 'local'})"
        )
        try:
            async with session.post(
                f"{base}/pair/initiate",
                json={"client_name": client_name},
                timeout=aiohttp.ClientTimeout(total=PAIR_INITIATE_TIMEOUT),
            ) as resp:
                if resp.status == 409:
                    # Bridge is already paired with another HA (single-pairing
                    # model). Surface this distinctly so we can tell the user to
                    # Reset Pairing on the bridge instead of a vague
                    # "cannot connect".
                    self._pair_result = "already_paired"
                    return
                if resp.status != 200:
                    self._pair_result = "error"
                    return
                data = await resp.json()
                request_id = data.get("request_id")
                if not request_id:
                    self._pair_result = "error"
                    return
        except (aiohttp.ClientError, TimeoutError) as err:
            # Log type only — never the raw exception (it embeds the request URL).
            _LOGGER.debug("Pair initiate failed (%s)", type(err).__name__)
            self._pair_result = "error"
            return

        # Use the running loop's clock (get_event_loop is deprecated when there
        # is no running loop; we are inside a task so there always is one).
        loop = self.hass.loop
        deadline = loop.time() + PAIR_MAX_WAIT
        while loop.time() < deadline:
            try:
                async with session.get(
                    f"{base}/pair/status/{request_id}",
                    timeout=aiohttp.ClientTimeout(total=HTTP_TIMEOUT),
                ) as resp:
                    if resp.status == 404:
                        # The bridge forgot this request id (expired/cleaned up
                        # or never existed). Fail fast instead of spinning for
                        # the full 5-minute deadline.
                        self._pair_result = "expired"
                        return
                    if resp.status != 200:
                        await asyncio.sleep(PAIR_POLL_INTERVAL)
                        continue
                    status = await resp.json()
            except (aiohttp.ClientError, TimeoutError):
                await asyncio.sleep(PAIR_POLL_INTERVAL)
                continue

            state = status.get("state")
            if state == "approved":
                token = status.get("token")
                if not token:
                    self._pair_result = "error"
                    return
                # The token is already committed on the bridge side at this
                # point. If the follow-up accessory fetch fails (transient
                # network blip), DON'T discard the approval — keep the token and
                # let setup fetch the snapshot later. We just expose an empty
                # selection list; the options flow can re-fetch.
                accs = await _fetch_accessories(self.hass, self._host, self._port, token)
                self._token = token
                self._accessories = accs if accs is not None else []
                self._pair_result = "approved"
                return
            if state in ("denied", "expired"):
                self._pair_result = state
                return
            # pending
            await asyncio.sleep(PAIR_POLL_INTERVAL)

        # Timed out without approval. Best-effort tell the bridge to drop the
        # pending request so an abandoned dialog doesn't linger (old bridges may
        # 404/405 this — ignore any failure).
        await self._abandon_pair(session, base, request_id)
        self._pair_result = "expired"

    async def _abandon_pair(self, session, base: str, request_id: str) -> None:
        """Best-effort DELETE of a pending pair request. Tolerant of old bridges
        that don't implement the endpoint (any error is ignored)."""
        try:
            async with session.delete(
                f"{base}/pair/{request_id}",
                timeout=aiohttp.ClientTimeout(total=HTTP_TIMEOUT),
            ):
                pass
        except Exception:  # noqa: BLE001
            pass

    async def async_step_pair_denied(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        return self.async_abort(reason="pair_denied")

    async def async_step_pair_expired(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        return self.async_abort(reason="pair_expired")

    async def async_step_pair_error(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        return self.async_abort(reason="cannot_connect")

    # ---------------------------------------------------------------- select

    async def async_step_select_devices(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        options, thorbolt_ids = _lock_options(self._accessories)
        # ThorBolts default ON (recommended); other locks are opt-in.
        schema, key_to_id = _checkbox_fields(options, default_ids=thorbolt_ids)
        if user_input is not None:
            enabled = [key_to_id[k] for k, on in user_input.items() if on and k in key_to_id]
            return self.async_create_entry(
                title=f"HA-LockBridge ({self._host})",
                data={
                    CONF_HOST: self._host,
                    CONF_PORT: self._port,
                    CONF_TOKEN: self._token,
                },
                options={CONF_ENABLED_IDS: enabled},
            )

        return self.async_show_form(
            step_id="select_devices",
            data_schema=schema,
            description_placeholders={
                "count": str(len(options)),
                "thorbolt_count": str(len(thorbolt_ids)),
            },
        )

    # ---------------------------------------------------------------- options

    @staticmethod
    @callback
    def async_get_options_flow(
        config_entry: config_entries.ConfigEntry,
    ) -> "HALockBridgeOptionsFlow":
        return HALockBridgeOptionsFlow(config_entry)


class HALockBridgeOptionsFlow(config_entries.OptionsFlow):
    """Re-select which accessories are exposed after initial setup."""

    def __init__(self, entry: config_entries.ConfigEntry) -> None:
        self.entry = entry

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> FlowResult:
        client = self.hass.data.get(DOMAIN, {}).get(self.entry.entry_id)
        # Prefer the bridge's authoritative /accessories snapshot: it's keyed per
        # physical accessory, so it can't carry the transient duplicate that
        # client.states accumulates when a lock's wire id changes mid-run (a
        # newly added lock is published first under a fallback id, then its
        # stable serial-hash id, with no 'removed' for the old one). Fall back
        # to local state only if the bridge is currently unreachable.
        accessories = await _fetch_accessories(
            self.hass,
            self.entry.data[CONF_HOST],
            self.entry.data[CONF_PORT],
            self.entry.data[CONF_TOKEN],
        )
        if accessories is None:
            accessories = (
                list(client.states.values()) if (client and client.states) else None
            )
            if accessories is None:
                return self.async_abort(reason="cannot_connect")

        options, _thorbolt_ids = _lock_options(accessories)

        # Distinguish "never configured" (None → a pre-options entry that exposed
        # everything, so default all checked) from an explicit empty selection
        # ([] → the user chose none, so default nothing checked).
        configured = self.entry.options.get(CONF_ENABLED_IDS)
        if configured is None:
            default_ids = list(options.keys())
        else:
            enabled_set = set(configured)
            default_ids = [aid for aid in options if aid in enabled_set]

        schema, key_to_id = _checkbox_fields(options, default_ids)
        if user_input is not None:
            enabled = [key_to_id[k] for k, on in user_input.items() if on and k in key_to_id]
            return self.async_create_entry(title="", data={CONF_ENABLED_IDS: enabled})

        return self.async_show_form(step_id="init", data_schema=schema)
