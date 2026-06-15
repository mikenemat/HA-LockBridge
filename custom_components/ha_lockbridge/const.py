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

# HTTP request timeout for snapshot/commands.
HTTP_TIMEOUT = 10.0

PLATFORMS = ["lock", "sensor", "binary_sensor"]

# Highest wire-protocol version this integration knows how to speak. The bridge
# may advertise a `protocol` integer in its WS hello + GET /info. We READ it
# tolerantly: absence means "assume 1" (old bridges predate the field), and a
# value greater than this means the bridge is newer than the integration — we
# log/repair but KEEP WORKING. Never hard-gate on this. Bump only when a NEW
# breaking wire change ships that the integration relies on.
MAX_SUPPORTED_PROTOCOL = 1

# HA bus event fired when the bridge reports it had to revert a write it could
# not complete (e.g. lock unreachable past the write budget). Additive: old
# bridges never send the `write_reverted` envelope, so this event simply never
# fires against them.
EVENT_WRITE_REVERTED = "ha_lockbridge_write_reverted"

# Signal name dispatched when accessory state arrives (one signal per entry).
SIGNAL_STATE_UPDATE = "ha_lockbridge_state_update_{entry_id}"
SIGNAL_REMOVED = "ha_lockbridge_removed_{entry_id}"
SIGNAL_CONNECTED = "ha_lockbridge_connected_{entry_id}"
SIGNAL_DISCONNECTED = "ha_lockbridge_disconnected_{entry_id}"
# Dispatched when the bridge reports an accessory id the integration has not yet
# created entities for, so platforms can add them dynamically (locks/sensors
# added mid-run, or whose battery/low-battery data arrived after first setup).
SIGNAL_NEW_ACCESSORY = "ha_lockbridge_new_accessory_{entry_id}"
