"""HTTP + WebSocket client for the HA-LockBridge.

Reliability contract:
- WS connection auto-reconnects with exponential backoff capped at WS_RECONNECT_MAX.
- Disconnect → all entities go unavailable via SIGNAL_DISCONNECTED, then SIGNAL_CONNECTED
  on the next successful snapshot.
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
    HTTP_TIMEOUT,
    SIGNAL_CONNECTED,
    SIGNAL_DISCONNECTED,
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

    # ------------------------------------------------------------------ URLs

    @property
    def _http_base(self) -> str:
        return f"http://{self._host}:{self._port}"

    @property
    def _ws_url(self) -> str:
        """URL used to actually open the WebSocket. Contains the bearer token
        as a query param — never include this in log output."""
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
        """Fetch /accessories synchronously during setup. Raises on failure."""
        url = f"{self._http_base}/accessories"
        timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
        async with self._session.get(url, headers=self._headers, timeout=timeout) as resp:
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

    def start_ws_loop(self) -> None:
        """Start the WS receive loop as a background task."""
        if self._ws_task and not self._ws_task.done():
            _LOGGER.debug("WS loop already running, skipping start")
            return
        _LOGGER.debug(
            "Starting WS loop for %s (token len=%d)", self._ws_url_for_log, len(self._token)
        )
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
        _LOGGER.warning("WS loop started (will connect to %s)", self._ws_url_for_log)
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
                _LOGGER.warning("Attempting WS connect to %s", self._ws_url_for_log)
                async with self._ws_session.ws_connect(
                    self._ws_url,
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
                    if not first_connect_logged:
                        _LOGGER.warning("WS connected to bridge")
                        first_connect_logged = True
                    self._dispatch(SIGNAL_CONNECTED)
                    await self._consume(ws)
            except asyncio.CancelledError:
                _LOGGER.debug("WS loop cancelled")
                raise
            except Exception as err:  # noqa: BLE001
                _LOGGER.warning(
                    "WebSocket disconnected (%s: %s). Reconnecting in %.1fs",
                    type(err).__name__,
                    err,
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

    async def _consume(self, ws: aiohttp.ClientWebSocketResponse) -> None:
        """Receive loop for a single connected WS session."""
        async for msg in ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                try:
                    self._handle_message(msg.json())
                except Exception:  # noqa: BLE001
                    _LOGGER.exception("WS message handler raised; continuing")
            elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSING, aiohttp.WSMsgType.CLOSED):
                _LOGGER.debug("WS close received")
                break
            elif msg.type == aiohttp.WSMsgType.ERROR:
                _LOGGER.warning("WS error frame: %s", ws.exception())
                break

    def _handle_message(self, payload: dict[str, Any]) -> None:
        mtype = payload.get("type")
        if mtype == "snapshot":
            new_states = {}
            for acc in payload.get("accessories", []):
                new_states[acc["id"]] = acc
            removed = set(self.states) - set(new_states)
            self.states = new_states
            for aid in self.states:
                self._dispatch(SIGNAL_STATE_UPDATE, self.states[aid])
            for aid in removed:
                self._dispatch(SIGNAL_REMOVED, aid)
        elif mtype == "state":
            acc = payload.get("accessory")
            if acc and "id" in acc:
                self.states[acc["id"]] = acc
                self._dispatch(SIGNAL_STATE_UPDATE, acc)
        elif mtype == "removed":
            aid = payload.get("id")
            if aid:
                self.states.pop(aid, None)
                self._dispatch(SIGNAL_REMOVED, aid)
        elif mtype == "hello":
            _LOGGER.debug("Bridge hello: %s", payload)
        else:
            _LOGGER.debug("Unknown WS message type: %s", mtype)

    # ------------------------------------------------------------------ dispatch

    def _dispatch(self, signal_template: str, *args: Any) -> None:
        signal = signal_template.format(entry_id=self.entry.entry_id)
        async_dispatcher_send(self.hass, signal, *args)
