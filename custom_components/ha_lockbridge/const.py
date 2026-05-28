"""Constants for the HA-LockBridge integration."""

DOMAIN = "ha_lockbridge"

CONF_HOST = "host"
CONF_PORT = "port"
CONF_TOKEN = "bearer_token"
CONF_ENABLED_IDS = "enabled_accessory_ids"

DEFAULT_PORT = 8765

# Bonjour service type the bridge advertises (mirrors BonjourService.swift).
ZEROCONF_TYPE = "_ha-lockbridge._tcp.local."

# Pair flow polling.
PAIR_INITIATE_TIMEOUT = 10.0
PAIR_POLL_INTERVAL = 2.0
PAIR_MAX_WAIT = 300.0  # bridge expires requests at 5 min, so don't poll longer

# Manufacturer string the Swift bridge reports for ThorBolt X1 locks.
THORBOLT_MANUFACTURER = "Sleekpoint Innovations"

# WebSocket reconnect backoff.
WS_RECONNECT_INITIAL = 1.0
WS_RECONNECT_MAX = 60.0
WS_RECEIVE_TIMEOUT = 45.0  # bridge pings every 15s, closes on 30s of silence

# HTTP request timeout for snapshot/commands.
HTTP_TIMEOUT = 10.0

PLATFORMS = ["lock", "sensor", "binary_sensor"]

# Signal name dispatched when accessory state arrives (one signal per entry).
SIGNAL_STATE_UPDATE = "ha_lockbridge_state_update_{entry_id}"
SIGNAL_REMOVED = "ha_lockbridge_removed_{entry_id}"
SIGNAL_CONNECTED = "ha_lockbridge_connected_{entry_id}"
SIGNAL_DISCONNECTED = "ha_lockbridge_disconnected_{entry_id}"
