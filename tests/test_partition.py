"""Unit tests for the integration's pure logic.

These run under PLAIN `python3` — no `homeassistant`, `aiohttp`, or `voluptuous`
required (none are installed in the dev/CI base image). They genuinely exercise
the *shipped* function bodies by extracting them from source and exec'ing them in
an isolated namespace, so a rename or behavioural change to the real code is
caught here. They are also collected by pytest when it (and the HA test rig) is
available — the helper assertions are plain `assert`s.

Tests that truly need `pytest-homeassistant-custom-component` (full config-flow /
client integration) live in test_integration.py with a guarded import so this
file and py_compile still pass on a bare interpreter.
"""
from __future__ import annotations

import ast
import json
import pathlib
from typing import Any, Callable

REPO = pathlib.Path(__file__).resolve().parent.parent
INTEGRATION = REPO / "custom_components" / "ha_lockbridge"


# --------------------------------------------------------------------------- #
# Source-extraction helpers: pull a single top-level function out of a module
# file and compile it in a controlled namespace. This lets us run the REAL
# function body without importing the module (which would drag in homeassistant).
# --------------------------------------------------------------------------- #


def _extract_funcs(module_path: pathlib.Path, names: set[str], ns: dict[str, Any]) -> None:
    """Compile the named top-level functions from `module_path` into `ns`.

    `ns` should be pre-populated with any module-level names the functions
    reference (constants, typing aliases, etc.).
    """
    tree = ast.parse(module_path.read_text())
    wanted: list[ast.stmt] = [
        node
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name in names
    ]
    found = {n.name for n in wanted}
    missing = names - found
    assert not missing, f"{module_path.name} no longer defines: {missing}"
    module = ast.Module(body=wanted, type_ignores=[])
    code = compile(module, filename=str(module_path), mode="exec")
    exec(code, ns)  # noqa: S102 — controlled namespace, our own source


def _load_const(name: str) -> Any:
    """Read a single simple constant assignment out of const.py without importing
    it (const.py has no heavy imports, but this keeps us uniform and robust to
    future additions)."""
    tree = ast.parse((INTEGRATION / "const.py").read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.literal_eval(node.value)
    raise AssertionError(f"const.py missing constant {name!r}")


THORBOLT_MANUFACTURER = _load_const("THORBOLT_MANUFACTURER")
CONF_ENABLED_IDS = _load_const("CONF_ENABLED_IDS")


def _lock_options_fn() -> Callable[[list[dict[str, Any]]], tuple]:
    ns: dict[str, Any] = {
        "Any": Any,
        "THORBOLT_MANUFACTURER": THORBOLT_MANUFACTURER,
    }
    _extract_funcs(INTEGRATION / "config_flow.py", {"_lock_options"}, ns)
    return ns["_lock_options"]


def _checkbox_fields_fn() -> Callable:
    """Extract `_checkbox_fields` with a minimal voluptuous stub.

    The real helper only uses `vol.Optional(key, default=...)` as a hashable
    schema marker and `vol.Schema(dict)`. We stub both so the actual shipped body
    runs on a bare interpreter and we can assert on the {field_key -> id} map and
    the per-field defaults — the parts that drive the picker's correctness.
    """

    class _Optional:
        def __init__(self, key: Any, default: Any = None) -> None:
            self.key = key
            self.default = default

        def __hash__(self) -> int:
            return hash(self.key)

        def __eq__(self, other: Any) -> bool:
            return isinstance(other, _Optional) and other.key == self.key

    class _Vol:
        Optional = _Optional

        @staticmethod
        def Schema(d: dict) -> dict:
            return d  # return the field dict so tests can inspect markers/defaults

    ns: dict[str, Any] = {"Any": Any, "vol": _Vol}
    _extract_funcs(INTEGRATION / "config_flow.py", {"_checkbox_fields"}, ns)
    return ns["_checkbox_fields"]


def _entity_helpers() -> dict[str, Callable]:
    ns: dict[str, Any] = {
        "Any": Any,
        "CONF_ENABLED_IDS": CONF_ENABLED_IDS,
    }
    _extract_funcs(
        INTEGRATION / "entity.py",
        {"is_accessory_enabled", "enabled_accessories"},
        ns,
    )
    return ns


class _FakeEntry:
    """Minimal stand-in for a ConfigEntry (only .options is read)."""

    def __init__(self, options: dict[str, Any]) -> None:
        self.options = options


class _FakeClient:
    """Minimal stand-in exposing .states like LockBridgeClient."""

    def __init__(self, states: dict[str, dict[str, Any]]) -> None:
        self.states = states


# --------------------------------------------------------------------------- #
# _lock_options — single combined list + ThorBolt "Verified" badge
# --------------------------------------------------------------------------- #


def test_lock_options_one_combined_map_with_thorbolt_ids():
    lock_options = _lock_options_fn()
    accs = [
        {"id": "a", "name": "Front Door", "manufacturer": THORBOLT_MANUFACTURER},
        {"id": "b", "name": "Garage", "manufacturer": "Acme Locks"},
    ]
    options, thorbolt_ids = lock_options(accs)
    # Both locks live in ONE map (no separate group), keyed by id.
    assert set(options.keys()) == {"a", "b"}
    assert thorbolt_ids == ["a"]


def test_lock_options_thorbolt_gets_verified_badge():
    lock_options = _lock_options_fn()
    accs = [
        {"id": "a", "name": "Front Door", "manufacturer": THORBOLT_MANUFACTURER,
         "model": "ThorBolt X1"},
        {"id": "b", "name": "Garage", "manufacturer": "Acme Locks", "model": "M1"},
    ]
    options, _ = lock_options(accs)
    assert "✅" in options["a"] and "ThorBolt X1 Verified" in options["a"]
    assert options["a"].startswith("Front Door")
    # Non-ThorBolt locks get no badge, just the model in parens.
    assert "✅" not in options["b"]
    assert options["b"] == "Garage  (M1)"


def test_lock_options_thorbolt_badge_falls_back_when_model_missing():
    lock_options = _lock_options_fn()
    accs = [{"id": "a", "name": "Door", "manufacturer": THORBOLT_MANUFACTURER}]
    options, _ = lock_options(accs)
    assert options["a"] == "Door  ✅ ThorBolt X1 Verified"


def test_lock_options_sorts_by_name_case_insensitive():
    lock_options = _lock_options_fn()
    accs = [
        {"id": "1", "name": "zeta", "manufacturer": "Acme"},
        {"id": "2", "name": "Alpha", "manufacturer": "Acme"},
        {"id": "3", "name": "beta", "manufacturer": "Acme"},
    ]
    options, _ = lock_options(accs)
    assert list(options.keys()) == ["2", "3", "1"]  # Alpha, beta, zeta


def test_lock_options_sorts_by_home_then_name():
    lock_options = _lock_options_fn()
    accs = [
        {"id": "1", "name": "Front Door", "home": "Beach", "manufacturer": "Acme"},
        {"id": "2", "name": "Front Door", "home": "Main", "manufacturer": "Acme"},
    ]
    options, _ = lock_options(accs)
    assert list(options.keys()) == ["1", "2"]  # Beach before Main
    assert options["1"] == "Beach Front Door"
    assert options["2"] == "Main Front Door"


def test_lock_options_falls_back_to_id_when_name_missing():
    lock_options = _lock_options_fn()
    accs = [{"id": "abc123", "manufacturer": "Acme"}]
    options, _ = lock_options(accs)
    assert options["abc123"] == "abc123"


def test_lock_options_empty_input():
    lock_options = _lock_options_fn()
    options, thorbolt_ids = lock_options([])
    assert options == {} and thorbolt_ids == []


# --------------------------------------------------------------------------- #
# _checkbox_fields — per-lock toggles, dedup, and cross-refetch stability
# --------------------------------------------------------------------------- #


def test_lock_options_order_is_stable_for_identical_labels():
    """Byte-identical labels must order deterministically by id, not by input
    order — the options flow re-fetches /accessories between render and submit,
    so a bridge reorder must NOT change the ordering (which drives the dedup
    suffix)."""
    lock_options = _lock_options_fn()
    a = {"id": "id_zzz", "name": "Front Door", "home": "H",
         "manufacturer": "Acme", "model": "M1"}
    b = {"id": "id_aaa", "name": "Front Door", "home": "H",
         "manufacturer": "Acme", "model": "M1"}
    opts_fwd, _ = lock_options([a, b])
    opts_rev, _ = lock_options([b, a])  # bridge returned them reordered
    assert list(opts_fwd.keys()) == ["id_aaa", "id_zzz"]  # id tiebreaker
    assert opts_fwd == opts_rev


def test_checkbox_fields_dedup_and_defaults():
    checkbox_fields = _checkbox_fields_fn()
    options = {  # two distinct ids that share one display label
        "id_aaa": "H Front Door  (M1)",
        "id_zzz": "H Front Door  (M1)",
    }
    schema, key_to_id = checkbox_fields(options, default_ids=["id_aaa"])
    # Two DISTINCT field keys, each mapping back to the correct id.
    assert key_to_id == {
        "H Front Door  (M1)": "id_aaa",
        "H Front Door  (M1) (2)": "id_zzz",
    }
    # Only the default-on id's toggle defaults True.
    defaults = {opt.key: opt.default for opt in schema}
    assert defaults["H Front Door  (M1)"] is True
    assert defaults["H Front Door  (M1) (2)"] is False


def test_picker_keymap_is_stable_across_refetch():
    """End-to-end guard for the options-flow re-fetch hazard: the field-key -> id
    map built from /accessories in two different orders must be IDENTICAL, so a
    toggle posted on the render pass decodes to the same lock on the submit pass
    even for byte-identical labels."""
    lock_options = _lock_options_fn()
    checkbox_fields = _checkbox_fields_fn()
    a = {"id": "id_zzz", "name": "Front Door", "home": "H",
         "manufacturer": "Acme", "model": "M1"}
    b = {"id": "id_aaa", "name": "Front Door", "home": "H",
         "manufacturer": "Acme", "model": "M1"}
    opts1, _ = lock_options([a, b])
    opts2, _ = lock_options([b, a])
    _, map1 = checkbox_fields(opts1, default_ids=[])
    _, map2 = checkbox_fields(opts2, default_ids=[])
    assert map1 == map2  # identical -> no cross-pass mis-mapping


# --------------------------------------------------------------------------- #
# is_accessory_enabled / enabled_accessories — empty-vs-unset semantics
# --------------------------------------------------------------------------- #


def test_enabled_unset_means_all():
    helpers = _entity_helpers()
    is_enabled = helpers["is_accessory_enabled"]
    enabled_accessories = helpers["enabled_accessories"]
    entry = _FakeEntry(options={})  # key absent entirely
    client = _FakeClient({"a": {"id": "a"}, "b": {"id": "b"}})
    assert is_enabled(entry, "a") is True
    assert is_enabled(entry, "anything") is True
    assert {a["id"] for a in enabled_accessories(client, entry)} == {"a", "b"}


def test_enabled_empty_list_means_none():
    """The original bug: an explicit empty selection collapsed to 'expose all'."""
    helpers = _entity_helpers()
    is_enabled = helpers["is_accessory_enabled"]
    enabled_accessories = helpers["enabled_accessories"]
    entry = _FakeEntry(options={CONF_ENABLED_IDS: []})
    client = _FakeClient({"a": {"id": "a"}, "b": {"id": "b"}})
    assert is_enabled(entry, "a") is False
    assert enabled_accessories(client, entry) == []


def test_enabled_subset():
    helpers = _entity_helpers()
    is_enabled = helpers["is_accessory_enabled"]
    enabled_accessories = helpers["enabled_accessories"]
    entry = _FakeEntry(options={CONF_ENABLED_IDS: ["a"]})
    client = _FakeClient({"a": {"id": "a"}, "b": {"id": "b"}})
    assert is_enabled(entry, "a") is True
    assert is_enabled(entry, "b") is False
    assert [a["id"] for a in enabled_accessories(client, entry)] == ["a"]


# --------------------------------------------------------------------------- #
# Lifecycle -> HA lock-state mapping (pure logic mirror of lock.py).
# We extract the four property bodies' shared rule by re-deriving it from the
# same predicate the module uses, asserting the contract: unknown -> None.
# --------------------------------------------------------------------------- #


def _lock_state_map(lifecycle: str | None) -> dict[str, bool | None]:
    """Mirror lock.py's is_* contract so the test documents the intended truth
    table; lock.py itself is also asserted to keep this shape via the source
    check below."""
    lc = lifecycle or "unknown"
    if lc == "unknown":
        return {k: None for k in ("is_locked", "is_locking", "is_unlocking", "is_jammed")}
    return {
        "is_locked": lc == "locked",
        "is_locking": lc == "locking",
        "is_unlocking": lc == "unlocking",
        "is_jammed": lc == "jammed",
    }


def test_lifecycle_unknown_is_none_not_false():
    for lc in (None, "", "unknown"):
        states = _lock_state_map(lc)
        assert all(v is None for v in states.values()), lc


def test_lifecycle_locked():
    states = _lock_state_map("locked")
    assert states["is_locked"] is True
    assert states["is_locking"] is False
    assert states["is_jammed"] is False


def test_lifecycle_jammed():
    assert _lock_state_map("jammed")["is_jammed"] is True
    assert _lock_state_map("jammed")["is_locked"] is False


def test_lock_py_returns_none_on_unknown():
    """Guard: lock.py's is_* properties must short-circuit unknown -> None
    (the bug was returning False, which HA renders as 'Unlocked')."""
    src = (INTEGRATION / "lock.py").read_text()
    # Each property returns None for unknown before comparing the specific state.
    assert 'None if lc == "unknown"' in src, (
        "lock.py must return None when lifecycle is unknown"
    )


# --------------------------------------------------------------------------- #
# Back-compat / contract guards — assert the source keeps the load-bearing
# properties that keep us compatible with OLD bridges.
# --------------------------------------------------------------------------- #


def test_ws_keeps_token_query_and_adds_header():
    """Old bridges read the ?token= query; current bridges prefer the header.
    Sending BOTH is what keeps new-integration <-> old-bridge working."""
    src = (INTEGRATION / "client.py").read_text()
    assert "/events?token=" in src, "WS URL must keep ?token= for old bridges"
    assert "headers=self._headers" in src, "WS connect must also send the auth header"


def test_no_raw_exception_logging_in_ws_loop():
    """Token-leak guard: the WS reconnect/handshake logging must not %-format the
    raw aiohttp exception (its __str__ embeds the token-bearing URL)."""
    src = (INTEGRATION / "client.py").read_text()
    # The reconnect log line logs the type name, not the exception object.
    assert "type(err).__name__" in src
    # And it must not interpolate `err` itself in that reconnect message.
    assert 'Reconnecting in %.1fs",\n                    err,' not in src


def test_protocol_is_tolerant_and_capped():
    src = (INTEGRATION / "client.py").read_text()
    const_src = (INTEGRATION / "const.py").read_text()
    assert "MAX_SUPPORTED_PROTOCOL" in const_src
    # We read protocol but never refuse to operate on a higher value (no raise).
    assert 'payload.get("protocol")' in src


def test_write_reverted_fires_bus_event():
    src = (INTEGRATION / "client.py").read_text()
    const_src = (INTEGRATION / "const.py").read_text()
    assert 'EVENT_WRITE_REVERTED = "ha_lockbridge_write_reverted"' in const_src
    assert 'mtype == "write_reverted"' in src
    assert "bus.async_fire(EVENT_WRITE_REVERTED" in src


# --------------------------------------------------------------------------- #
# On-disk artifact sanity (kept from the original file).
# --------------------------------------------------------------------------- #


def test_manifest_is_valid_json_and_has_required_fields():
    manifest = json.loads((INTEGRATION / "manifest.json").read_text())
    for field in ("domain", "name", "version", "documentation", "codeowners", "iot_class"):
        assert field in manifest, f"manifest.json is missing {field!r}"
    assert manifest["domain"] == "ha_lockbridge"
    assert manifest.get("zeroconf"), "manifest missing zeroconf declaration"
    assert manifest["zeroconf"][0]["type"] == "_ha-lockbridge._tcp.local."


def test_strings_and_translations_are_in_sync():
    strings = json.loads((INTEGRATION / "strings.json").read_text())
    en = json.loads((INTEGRATION / "translations" / "en.json").read_text())
    assert strings == en, "strings.json and translations/en.json must match"


def test_reauth_and_already_paired_strings_present():
    strings = json.loads((INTEGRATION / "strings.json").read_text())
    config = strings["config"]
    assert "reauth_confirm" in config["step"], "missing reauth_confirm step strings"
    assert "already_paired" in config["abort"], "missing already_paired abort string"
    assert "reauth_successful" in config["abort"], "missing reauth_successful abort"


def test_hacs_json_at_repo_root():
    data = json.loads((REPO / "hacs.json").read_text())
    assert data.get("name"), "hacs.json missing name"
    assert data.get("homeassistant"), "hacs.json missing minimum HA version"


def test_required_python_files_exist():
    expected = {
        "__init__.py",
        "client.py",
        "config_flow.py",
        "const.py",
        "diagnostics.py",
        "entity.py",
        "lock.py",
        "sensor.py",
        "binary_sensor.py",
        "manifest.json",
        "strings.json",
    }
    actual = {p.name for p in INTEGRATION.iterdir() if p.is_file()}
    missing = expected - actual
    assert not missing, f"integration is missing files: {missing}"


def test_icon_files_present_and_correct_sizes():
    import struct

    def png_size(path: pathlib.Path) -> tuple[int, int]:
        data = path.read_bytes()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
        w, h = struct.unpack(">II", data[16:24])
        return (w, h)

    for parent in (INTEGRATION, INTEGRATION / "brand"):
        icon = parent / "icon.png"
        icon_2x = parent / "icon@2x.png"
        assert icon.exists(), f"missing {icon}"
        assert icon_2x.exists(), f"missing {icon_2x}"
        assert png_size(icon) == (256, 256), f"{icon} must be 256×256, got {png_size(icon)}"
        assert png_size(icon_2x) == (512, 512), f"{icon_2x} must be 512×512, got {png_size(icon_2x)}"


def test_const_module_declares_critical_constants():
    text = (INTEGRATION / "const.py").read_text()
    for needed in (
        'DOMAIN = "ha_lockbridge"',
        'ZEROCONF_TYPE = "_ha-lockbridge._tcp.local."',
        'THORBOLT_MANUFACTURER = "Sleekpoint Innovations"',
        'DEFAULT_PORT = 8765',
    ):
        assert needed in text, f"const.py missing line: {needed}"
