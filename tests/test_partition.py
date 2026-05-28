"""Sanity tests for the HA integration package.

These don't actually import the HA integration (Python's relative-import rules
make that a pain without a full pytest+homeassistant test rig). Instead they
verify the on-disk artifacts are well-formed — which catches the regressions
that have actually bitten us in development.
"""
from __future__ import annotations

import json
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
INTEGRATION = REPO / "custom_components" / "ha_lockbridge"


def test_manifest_is_valid_json_and_has_required_fields():
    manifest = json.loads((INTEGRATION / "manifest.json").read_text())
    for field in ("domain", "name", "version", "documentation", "codeowners", "iot_class"):
        assert field in manifest, f"manifest.json is missing {field!r}"
    assert manifest["domain"] == "ha_lockbridge"
    # zeroconf service type must match what the Swift bridge advertises
    assert manifest.get("zeroconf"), "manifest missing zeroconf declaration"
    assert manifest["zeroconf"][0]["type"] == "_ha-lockbridge._tcp.local."


def test_strings_and_translations_are_in_sync():
    strings = json.loads((INTEGRATION / "strings.json").read_text())
    en = json.loads((INTEGRATION / "translations" / "en.json").read_text())
    assert strings == en, "strings.json and translations/en.json must match"


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
        "diagnostics.py",   # added for productionization
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
    """HACS UI reads icon.png/icon@2x.png from the integration root.
    HA core (2026.3+) reads them from `brand/` via the brands-proxy-API.
    Both paths must exist at the correct sizes."""
    import struct

    def png_size(path: pathlib.Path) -> tuple[int, int]:
        data = path.read_bytes()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
        # IHDR chunk starts at byte 8; size is bytes 16-23 (big-endian uint32 width+height)
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
    """Without importing — just grep the file for the constants we depend on
    across both bridge and integration. Catches accidental rename regressions."""
    text = (INTEGRATION / "const.py").read_text()
    for needed in (
        'DOMAIN = "ha_lockbridge"',
        'ZEROCONF_TYPE = "_ha-lockbridge._tcp.local."',
        'THORBOLT_MANUFACTURER = "Sleekpoint Innovations"',
        'DEFAULT_PORT = 8765',
    ):
        assert needed in text, f"const.py missing line: {needed}"
