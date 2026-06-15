"""HTTP + WebSocket client for the HA-LockBridge.

Reliability contract:
- WS connection auto-reconnects with exponential backoff capped at WS_RECONNECT_MAX.
- Disconnect → all entities go unavailable via SIGNAL_DISCONNECTED. On reconnect we
  do NOT dispatch SIGNAL_CONNECTED until the bridge has delivered the first snapshot
  of that session, so entities never report "available" while still holding stale
  pre-reconnect state.
- aiohttp `heartbeat=15` makes the client send pings so it sees activity even
  during idle (the bridge sends its own pings too; both sides know the link
  is alive). `receive_timeout=60` is the hard ceiling on per-message wait time
  that catches half-open TCP.
- HTTP commands have a 10s timeout. Failures bubble to the caller (entity service
  handler) which surfaces them in HA's UI.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import aiohttp
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.dispatcher import async_dispatcher_send

from .const import (
    CONF_HOST,
    CONF_PORT,
    CONF_TOKEN,
    DOMAIN,
    EVENT_WRITE_REVERTED,
    HTTP_TIMEOUT,
    MAX_SUPPORTED_PROTOCOL,
    SIGNAL_CONNECTED,
    SIGNAL_DISCONNECTED,
    SIGNAL_NEW_ACCESSORY,
    SIGNAL_REMOVED,
    SIGNAL_STATE_UPDATE,
    WS_RECONNECT_INITIAL,
    WS_RECONNECT_MAX,
)

_LOGGER = logging.getLogger(__name__)


class LockBridgeClient:
    """Owns one HTTP+WS connection to a bridge instance."""

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        # HTTP requests use HA's shared session (pooled, cookie-aware, etc.)
        self._session: aiohttp.ClientSession = async_get_clientsession(hass)
        # The WebSocket needs its OWN session backed by its OWN connector.
        # Two intertwined constraints:
        #
        # A) NIO's HTTP server removes its WS-upgrade handler from the pipeline
        #    after the first request on a TCP connection (per HTTP spec —
        #    upgrade is a one-shot per-connection state change). If our WS
        #    connection were pooled with a prior `/accessories` HTTP GET,
        #    the bridge would see the upgrade request on a connection where
        #    the upgrader is gone, fall through to the regular HTTP handler,
        #    and 404 `/events`. Solution: `TCPConnector(force_close=True)` —
        #    each request gets a brand-new TCP socket, never pooled.
        #
        # B) aiohttp's default resolver when `aiodns` is installed (HA includes
        #    it) is `AsyncResolver`, which uses c-ares — and c-ares does not
        #    do mDNS. So `.local` lookups fail with "DNS server returned
        #    general failure". Solution: pin `aiohttp.ThreadedResolver()`,
        #    which uses Python's `getaddrinfo` (going through nsswitch and
        #    therefore nss-mdns) and resolves `.local` correctly.
        #
        # HA's own `async_create_clientsession` gives us neither of these —
        # it reuses HA's global connector (shared pool, no force_close).
        self._ws_session: aiohttp.ClientSession | None = None
        # Reference to the currently-open WS so shutdown can close it cleanly
        # (sending a CLOSE frame and letting aiohttp's heartbeat task finish
        # gracefully) instead of yanking the transport out from under aiohttp.
        self._active_ws: aiohttp.ClientWebSocketResponse | None = None
        self._host: str = entry.data[CONF_HOST]
        self._port: int = entry.data[CONF_PORT]
        self._token: str = entry.data[CONF_TOKEN]
        self._ws_task: asyncio.Task | None = None
        self._shutdown = asyncio.Event()
        # Latest known state keyed by accessory id.
        self.states: dict[str, dict[str, Any]] = {}
        self.connected: bool = False
        # Wire-protocol version the bridge last advertised in its WS `hello`
        # (or `/info`). None until we've seen a hello; treated as 1 (the
        # implicit version of every old bridge that predates the field).
        self.protocol: int | None = None
        # Set when the bridge rejects the bearer token (HTTP 401 / WS 401 on the
        # handshake). The setup path reads this to raise ConfigEntryAuthFailed so
        # HA starts the reauth flow instead of looping forever.
        self.auth_failed: bool = False
        # Callback the entry can register to be notified of an auth failure
        # discovered asynchronously inside the WS loop (so it can start reauth).
        self._on_auth_failed: Any = None
        # True once we've delivered the first snapshot of the *current* WS
        # session. We hold SIGNAL_CONNECTED until then so entities never see a
        # brief "available with stale state" window right after a reconnect.
        self._session_snapshot_seen: bool = False

    # ------------------------------------------------------------------ URLs

    @property
    def _http_base(self) -> str:
        return f"http://{self._host}:{self._port}"

    @property
    def _ws_url(self) -> str:
        """URL used to actually open the WebSocket. Contains the bearer token
        as a query param — never include this in log output.

        Back-compat: we keep the `?token=` query param so OLD bridges (which
        only read the query) keep authenticating, AND we additionally send the
        `Authorization: Bearer` header (see `_headers`) which the current bridge
        checks first. Sending both is safe on every bridge version; dropping the
        query param would break old bridges, so we never do that.
        """
        return f"ws://{self._host}:{self._port}/events?token={self._token}"

    @property
    def _ws_url_for_log(self) -> str:
        """Token-redacted URL safe to write to logs."""
        return f"ws://{self._host}:{self._port}/events"

    @property
    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._token}"}

    # ------------------------------------------------------------------ HTTP

    async def async_initial_snapshot(self) -> list[dict[str, Any]]:
        """Fetch /accessories synchronously during setup. Raises on failure.

        Raises PermissionError on 401 so the setup path can map it to
        ConfigEntryAuthFailed (kicking off reauth) instead of treating a stale
        token as a transient connectivity problem.
        """
        url = f"{self._http_base}/accessories"
        timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
        async with self._session.get(url, headers=self._headers, timeout=timeout) as resp:
            if resp.status == 401:
                self.auth_failed = True
                raise PermissionError("bearer token rejected")
            resp.raise_for_status()
            data = await resp.json()
        accessories = data.get("accessories", [])
        for acc in accessories:
            self.states[acc["id"]] = acc
        _LOGGER.debug("Initial snapshot: %d accessories", len(accessories))
        return accessories

    async def async_set_target(self, accessory_id: str, target: str) -> dict[str, Any]:
        """POST /accessories/{id}/state. Returns the updated state. Raises on failure."""
        if target not in ("secured", "unsecured"):
            raise ValueError(f"invalid target: {target!r}")
        url = f"{self._http_base}/accessories/{accessory_id}/state"
        timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
        async with self._session.post(
            url, headers=self._headers, json={"target": target}, timeout=timeout
        ) as resp:
            if resp.status == 401:
                raise PermissionError("bearer token rejected")
            if resp.status == 404:
                raise LookupError(f"accessory {accessory_id} not known to bridge")
            if resp.status == 503:
                raise ConnectionError("accessory unreachable from bridge")
            resp.raise_for_status()
            return await resp.json()

    # ------------------------------------------------------------------ WS

    def register_auth_failed_callback(self, cb: Any) -> None:
        """Register a coroutine/callback invoked when the WS handshake gets a
        401, so the entry can start the reauth flow. Token never logged."""
        self._on_auth_failed = cb

    def start_ws_loop(self) -> None:
        """Start the WS receive loop as a background task."""
        if self._ws_task and not self._ws_task.done():
            _LOGGER.debug("WS loop already running, skipping start")
            return
        # Never log the token (not even its length) or the token-bearing URL.
        _LOGGER.debug("Starting WS loop for %s", self._ws_url_for_log)
        self._ws_task = self.hass.loop.create_task(self._ws_loop(), name="lockbridge_ws")

    async def async_shutdown(self) -> None:
        """Stop the WS loop and clean up. Idempotent.

        Order matters: we close the active WS first (sends a proper CLOSE
        frame, lets aiohttp's internal heartbeat task wind down without
        racing a transport close), then wait briefly for _ws_loop to exit
        on its own via the shutdown event, then cancel as a fallback, then
        close the session.
        """
        self._shutdown.set()

        # 1. Politely close the live WS so aiohttp's heartbeat task can finish
        if self._active_ws is not None and not self._active_ws.closed:
            try:
                await self._active_ws.close()
            except Exception:  # noqa: BLE001
                pass

        # 2. Wait for _ws_loop to notice the shutdown event and return cleanly
        if self._ws_task and not self._ws_task.done():
            try:
                await asyncio.wait_for(self._ws_task, timeout=3.0)
            except asyncio.TimeoutError:
                # Took too long; force-cancel
                self._ws_task.cancel()
                try:
                    await self._ws_task
                except (asyncio.CancelledError, Exception):  # noqa: BLE001
                    pass
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass

        # 3. Tear down the session
        if self._ws_session is not None and not self._ws_session.closed:
            await self._ws_session.close()
            self._ws_session = None

    async def _ws_loop(self) -> None:
        """Connect WS, receive events, reconnect on any failure."""
        _LOGGER.debug("WS loop started (will connect to %s)", self._ws_url_for_log)
        # Lazily create our dedicated WS session inside the loop so it lives on
        # HA's event loop (it would error if created at __init__ time before
        # the loop is running).
        try:
            if self._ws_session is None or self._ws_session.closed:
                # Isolated connector: force_close prevents pooling (so the bridge's
                # WS upgrader is always installed for our connection), and
                # ThreadedResolver makes `.local` work via the system resolver.
                connector = aiohttp.TCPConnector(
                    force_close=True,
                    resolver=aiohttp.ThreadedResolver(),
                )
                self._ws_session = aiohttp.ClientSession(connector=connector)
        except Exception:  # noqa: BLE001
            _LOGGER.exception("Failed to create dedicated WS ClientSession")
            return

        backoff = WS_RECONNECT_INITIAL
        first_connect_logged = False
        while not self._shutdown.is_set():
            try:
                _LOGGER.debug("Attempting WS connect to %s", self._ws_url_for_log)
                # Back-compat: the URL still carries `?token=` for old bridges,
                # AND we pass the Authorization header that the current bridge
                # prefers. The header value is never logged.
                async with self._ws_session.ws_connect(
                    self._ws_url,
                    headers=self._headers,
                    # aiohttp sends its own pings every 15s. Combined with the
                    # bridge's pings, both sides know the link is alive even
                    # during long idle periods. Without this, `receive_timeout`
                    # could fire because control frames (PING/PONG) don't reset
                    # the data-message timer.
                    heartbeat=15.0,
                    # Hard ceiling so half-open TCP eventually surfaces.
                    receive_timeout=60.0,
                    autoping=True,  # respond to server pings automatically
                ) as ws:
                    backoff = WS_RECONNECT_INITIAL  # reset after successful connect
                    self._active_ws = ws  # so shutdown can close it cleanly
                    self.connected = True
                    # New WS session: hold SIGNAL_CONNECTED until the bridge has
                    # delivered the first snapshot (see _handle_message). This
                    # closes the stale-available window on reconnect.
                    self._session_snapshot_seen = False
                    if not first_connect_logged:
                        _LOGGER.info("WS connected to bridge")
                        first_connect_logged = True
                    await self._consume(ws)
            except asyncio.CancelledError:
                _LOGGER.debug("WS loop cancelled")
                raise
            except aiohttp.WSServerHandshakeError as err:
                # Log only the HTTP status — never the exception's str (it
                # embeds the token-bearing URL).
                _LOGGER.debug(
                    "WS handshake rejected (status=%s) for %s",
                    getattr(err, "status", "?"),
                    self._ws_url_for_log,
                )
                if getattr(err, "status", None) == 401:
                    # Stale/revoked token. No amount of retrying fixes this;
                    # surface it so the entry can start reauth, then stop.
                    self.auth_failed = True
                    self._notify_auth_failed()
                    if self.connected:
                        self.connected = False
                        self._dispatch(SIGNAL_DISCONNECTED)
                    return
            except Exception as err:  # noqa: BLE001
                # Never %-format the raw aiohttp exception: its __str__ can
                # include the token-bearing request URL. Log the type only.
                _LOGGER.debug(
                    "WebSocket disconnected (%s). Reconnecting in %.1fs",
                    type(err).__name__,
                    backoff,
                )
            finally:
                self._active_ws = None
                if self.connected:
                    self.connected = False
                    self._dispatch(SIGNAL_DISCONNECTED)
            if self._shutdown.is_set():
                return
            try:
                await asyncio.wait_for(self._shutdown.wait(), timeout=backoff)
                return  # shutdown signalled during sleep
            except asyncio.TimeoutError:
                pass
            backoff = min(backoff * 2, WS_RECONNECT_MAX)

    def _notify_auth_failed(self) -> None:
        """Invoke the registered auth-failed callback (sync or coroutine)."""
        cb = self._on_auth_failed
        if cb is None:
            return
        try:
            result = cb()
            if asyncio.iscoroutine(result):
                self.hass.loop.create_task(result)
        except Exception:  # noqa: BLE001
            _LOGGER.debug("auth-failed callback raised", exc_info=False)

    async def _consume(self, ws: aiohttp.ClientWebSocketResponse) -> None:
        """Receive loop for a single connected WS session."""
        async for msg in ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                try:
                    payload = msg.json()
                except ValueError:
                    # Malformed JSON frame — skip it without tearing down the
                    # session. Don't log the raw frame (could be anything).
                    _LOGGER.debug("Skipping non-JSON WS frame")
                    continue
                if not isinstance(payload, dict):
                    _LOGGER.debug("Skipping non-object WS frame")
                    continue
                try:
                    self._handle_message(payload)
                except Exception:  # noqa: BLE001
                    _LOGGER.exception("WS message handler raised; continuing")
            elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSING, aiohttp.WSMsgType.CLOSED):
                _LOGGER.debug("WS close received")
                break
            elif msg.type == aiohttp.WSMsgType.ERROR:
                # ws.exception() can carry the token-bearing URL — log type only.
                exc = ws.exception()
                _LOGGER.debug("WS error frame (%s)", type(exc).__name__)
                break

    def _handle_message(self, payload: dict[str, Any]) -> None:
        mtype = payload.get("type")
        if mtype == "snapshot":
            new_states = {}
            for acc in payload.get("accessories", []):
                if isinstance(acc, dict) and "id" in acc:
                    new_states[acc["id"]] = acc
            added = set(new_states) - set(self.states)
            removed = set(self.states) - set(new_states)
            self.states = new_states
            for aid in self.states:
                self._dispatch(SIGNAL_STATE_UPDATE, self.states[aid])
            # Announce ids we hadn't seen so platforms can create entities for
            # locks added mid-run (or whose battery data arrived late).
            for aid in added:
                self._dispatch(SIGNAL_NEW_ACCESSORY, self.states[aid])
            for aid in removed:
                self._dispatch(SIGNAL_REMOVED, aid)
            # Gate SIGNAL_CONNECTED on the first snapshot of this WS session so
            # entities only flip "available" once they have fresh state.
            self._mark_session_connected()
        elif mtype == "state":
            acc = payload.get("accessory")
            if isinstance(acc, dict) and "id" in acc:
                is_new = acc["id"] not in self.states
                self.states[acc["id"]] = acc
                self._dispatch(SIGNAL_STATE_UPDATE, acc)
                if is_new:
                    self._dispatch(SIGNAL_NEW_ACCESSORY, acc)
                # A `state` before any `snapshot` still counts as fresh data —
                # flip connected so we never stay unavailable against a bridge
                # whose first frame is a `state` rather than a `snapshot`.
                self._mark_session_connected()
        elif mtype == "removed":
            aid = payload.get("id")
            if aid:
                self.states.pop(aid, None)
                self._dispatch(SIGNAL_REMOVED, aid)
        elif mtype == "write_reverted":
            # Additive, tolerant envelope (bridge -> HA). Old bridges never send
            # it. Fire an HA bus event so users can automate on it; the payload
            # fields are read defensively.
            self._handle_write_reverted(payload)
        elif mtype == "hello":
            # Read the optional `protocol` integer tolerantly. Absent => the
            # bridge predates the field; assume protocol 1. We never refuse to
            # operate based on this value.
            proto = payload.get("protocol")
            if isinstance(proto, int):
                self.protocol = proto
                if proto > MAX_SUPPORTED_PROTOCOL:
                    _LOGGER.warning(
                        "Bridge speaks wire protocol %d but this integration "
                        "supports up to %d. Some newer bridge features may be "
                        "ignored — update the Home Assistant integration. "
                        "Continuing with the features we understand.",
                        proto,
                        MAX_SUPPORTED_PROTOCOL,
                    )
                    self._raise_protocol_issue(proto)
            else:
                # No protocol field: behave exactly as before (assume v1).
                self.protocol = self.protocol or 1
            _LOGGER.debug("Bridge hello received (protocol=%s)", self.protocol)
        else:
            _LOGGER.debug("Unknown WS message type: %s", mtype)

    def _mark_session_connected(self) -> None:
        """Dispatch SIGNAL_CONNECTED exactly once per WS session, on the first
        data message (snapshot or state). Holding it until here closes the
        stale-available window on reconnect."""
        if not self._session_snapshot_seen:
            self._session_snapshot_seen = True
            self._dispatch(SIGNAL_CONNECTED)

    def _raise_protocol_issue(self, bridge_protocol: int) -> None:
        """Raise a non-blocking repairs issue telling the user to update the
        integration. Best-effort + guarded: never let a repairs-API quirk break
        the WS loop, and never hard-gate on protocol."""
        try:
            from homeassistant.helpers import issue_registry as ir

            ir.async_create_issue(
                self.hass,
                DOMAIN,
                f"unsupported_protocol_{self.entry.entry_id}",
                is_fixable=False,
                severity=ir.IssueSeverity.WARNING,
                translation_key="unsupported_protocol",
                translation_placeholders={
                    "bridge_protocol": str(bridge_protocol),
                    "supported_protocol": str(MAX_SUPPORTED_PROTOCOL),
                },
            )
        except Exception:  # noqa: BLE001
            _LOGGER.debug("Could not raise protocol repairs issue", exc_info=False)

    def _handle_write_reverted(self, payload: dict[str, Any]) -> None:
        """Fire ha_lockbridge_write_reverted on the HA bus for a reverted write.

        Defensive: every field is optional. Old bridges never emit this, so the
        absence of the envelope is simply "feature not present", never an error.
        """
        wire_id = payload.get("id")
        target = payload.get("target")
        reason = payload.get("reason")
        name = payload.get("accessory_name")
        # Best-effort: backfill the accessory name from local state if the
        # bridge didn't include it.
        if not name and isinstance(wire_id, str):
            acc = self.states.get(wire_id)
            if isinstance(acc, dict):
                name = acc.get("name")
        event_data = {
            "entry_id": self.entry.entry_id,
            "id": wire_id,
            "name": name,
            "target": target,
            "reason": reason,
        }
        _LOGGER.info(
            "Bridge reverted a write (target=%s reason=%s) for %s",
            target,
            reason,
            name or wire_id,
        )
        self.hass.bus.async_fire(EVENT_WRITE_REVERTED, event_data)

    # ------------------------------------------------------------------ dispatch

    def _dispatch(self, signal_template: str, *args: Any) -> None:
        signal = signal_template.format(entry_id=self.entry.entry_id)
        async_dispatcher_send(self.hass, signal, *args)
