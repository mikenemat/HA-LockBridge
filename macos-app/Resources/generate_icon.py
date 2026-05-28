#!/usr/bin/env python3
"""Generate a simple lock-glyph app icon at 1024×1024 PNG.

Run this whenever you want to regenerate the icon from scratch:
    python3 Resources/generate_icon.py

Output: Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
        Resources/icon_512.png   (for HA integration use)

The design is intentionally simple — replace with real artwork when you have it.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw


HERE = Path(__file__).resolve().parent
APPICON_DIR = HERE / "Assets.xcassets" / "AppIcon.appiconset"
HA_ICON_DIR = HERE.parent.parent / "custom_components" / "ha_lockbridge"

PRIMARY = (37, 99, 235)      # blue-600
PRIMARY_DEEP = (29, 78, 216) # blue-700
ACCENT = (52, 211, 153)      # emerald-400, used for the "bridge" dot
WHITE = (255, 255, 255)


def linear_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = img.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(size):
            pixels[x, y] = (r, g, b, 255)
    return img


def rounded_mask(size: int, corner: int) -> Image.Image:
    """Squircle-ish mask via rounded rectangle."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), (size - 1, size - 1)], radius=corner, fill=255)
    return mask


def draw_lock(canvas: Image.Image, color: tuple[int, int, int]) -> None:
    """Centered lock glyph."""
    size = canvas.size[0]
    draw = ImageDraw.Draw(canvas)

    # Lock body (rounded rectangle, lower half)
    body_w = int(size * 0.48)
    body_h = int(size * 0.34)
    body_x = (size - body_w) // 2
    body_y = int(size * 0.50)
    body_radius = int(body_w * 0.14)
    draw.rounded_rectangle(
        [(body_x, body_y), (body_x + body_w, body_y + body_h)],
        radius=body_radius,
        fill=color,
    )

    # Shackle: a thick U-curve sitting on top of the body
    shackle_w = int(body_w * 0.62)
    shackle_thickness = int(body_w * 0.15)
    shackle_x = (size - shackle_w) // 2
    shackle_top = int(size * 0.22)
    # The U-curve (top arc only — `arc` with `width` draws a stroked path,
    # not a filled sector like `pieslice` does).
    draw.arc(
        [(shackle_x, shackle_top), (shackle_x + shackle_w, shackle_top + shackle_w)],
        start=180, end=360, fill=color, width=shackle_thickness,
    )
    # Vertical bars connecting the arc endpoints down to the body. Start them
    # at the arc's center-y so they butt cleanly against the arc curve.
    arc_center_y = shackle_top + shackle_w // 2
    bar_top = arc_center_y - shackle_thickness // 2
    bar_bottom = body_y + body_radius
    draw.rectangle(
        [(shackle_x, bar_top),
         (shackle_x + shackle_thickness, bar_bottom)],
        fill=color,
    )
    draw.rectangle(
        [(shackle_x + shackle_w - shackle_thickness, bar_top),
         (shackle_x + shackle_w, bar_bottom)],
        fill=color,
    )

    # Keyhole accent
    kh_radius = int(body_w * 0.07)
    kh_cx = size // 2
    kh_cy = body_y + body_h // 2 - int(body_h * 0.05)
    draw.ellipse(
        [(kh_cx - kh_radius, kh_cy - kh_radius),
         (kh_cx + kh_radius, kh_cy + kh_radius)],
        fill=(0, 0, 0, 70),
    )


def draw_bridge_dot(canvas: Image.Image, color: tuple[int, int, int]) -> None:
    """Small accent dot in the top-right suggesting connectivity."""
    size = canvas.size[0]
    dot_size = int(size * 0.10)
    pad = int(size * 0.08)
    x = size - pad - dot_size
    y = pad
    draw = ImageDraw.Draw(canvas)
    draw.ellipse([(x, y), (x + dot_size, y + dot_size)], fill=color)


def make_icon(size: int = 1024) -> Image.Image:
    # Gradient background
    bg = linear_gradient(size, PRIMARY, PRIMARY_DEEP)
    # Apply rounded mask (the Mac OS icon container does its own corner masking
    # too, but a baked-in soft mask looks cleaner on light backgrounds)
    corner = int(size * 0.225)  # ~Apple squircle ratio
    mask = rounded_mask(size, corner)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), mask)

    # Draw the lock + accent
    draw_lock(out, WHITE)
    draw_bridge_dot(out, ACCENT)
    return out


def write_appiconset(icon: Image.Image) -> None:
    APPICON_DIR.mkdir(parents=True, exist_ok=True)
    icon.save(APPICON_DIR / "icon_1024.png", "PNG")
    contents = """{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
    (APPICON_DIR / "Contents.json").write_text(contents)

    # Asset catalog root manifest
    assets_root = APPICON_DIR.parent
    (assets_root / "Contents.json").write_text(
        '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
    )


def write_ha_icon(icon: Image.Image) -> None:
    HA_ICON_DIR.mkdir(parents=True, exist_ok=True)
    # HACS UI reads the icons from the root of the integration directory:
    icon.resize((256, 256), Image.LANCZOS).save(HA_ICON_DIR / "icon.png", "PNG")
    icon.resize((512, 512), Image.LANCZOS).save(HA_ICON_DIR / "icon@2x.png", "PNG")
    # HA core (2026.3+) reads them from the `brand/` subfolder via the
    # brands-proxy-API. We write to both so HACS and HA both render correctly
    # without needing a PR to home-assistant/brands.
    brand_dir = HA_ICON_DIR / "brand"
    brand_dir.mkdir(parents=True, exist_ok=True)
    icon.resize((256, 256), Image.LANCZOS).save(brand_dir / "icon.png", "PNG")
    icon.resize((512, 512), Image.LANCZOS).save(brand_dir / "icon@2x.png", "PNG")


def make_status_bar_icon(size: int = 88) -> Image.Image:
    """Monochrome 'template' icon for the macOS menu bar.

    Designed to echo the Dock icon: thin rounded frame, lock glyph inside,
    accent dot in the top-right corner. macOS expects status bar icons to be
    solid black on transparent so the OS can tint them appropriately for
    light/dark mode. Final-size target is 22pt @1x / 44px @2x — we render
    at 4× (88px) and let LANCZOS downsample.
    """
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(out)
    BLACK = (0, 0, 0, 255)

    # Thin rounded frame around everything. Stroke width ~1px at the 22pt
    # native size (≈4px at 88px canvas).
    stroke = max(2, round(size * 0.045))
    pad = max(2, round(size * 0.06))
    corner = max(2, round(size * 0.18))
    draw.rounded_rectangle(
        [(pad, pad), (size - pad - 1, size - pad - 1)],
        radius=corner, outline=BLACK, width=stroke,
    )

    # Lock body — smaller than the un-framed version to leave breathing
    # room inside the frame.
    body_w = int(size * 0.36)
    body_h = int(size * 0.22)
    body_x = (size - body_w) // 2
    body_y = int(size * 0.54)
    body_radius = max(2, int(body_w * 0.18))
    draw.rounded_rectangle(
        [(body_x, body_y), (body_x + body_w, body_y + body_h)],
        radius=body_radius, fill=BLACK,
    )

    # U-shaped shackle above the body
    shackle_w = int(body_w * 0.62)
    shackle_thickness = max(2, int(body_w * 0.22))
    shackle_x = (size - shackle_w) // 2
    shackle_top = int(size * 0.32)
    draw.arc(
        [(shackle_x, shackle_top), (shackle_x + shackle_w, shackle_top + shackle_w)],
        start=180, end=360, fill=BLACK, width=shackle_thickness,
    )
    arc_center_y = shackle_top + shackle_w // 2
    bar_top = arc_center_y - shackle_thickness // 2
    bar_bottom = body_y + body_radius
    draw.rectangle(
        [(shackle_x, bar_top), (shackle_x + shackle_thickness, bar_bottom)],
        fill=BLACK,
    )
    draw.rectangle(
        [(shackle_x + shackle_w - shackle_thickness, bar_top),
         (shackle_x + shackle_w, bar_bottom)],
        fill=BLACK,
    )

    # Accent dot in the top-right corner — echoes the green bridge-dot in
    # the colored Dock icon. Rendered as a black disk with a transparent
    # hole so it reads as a "white" pip against the menu bar in light mode
    # (and inverts to a light pip with a dark center in dark mode, since
    # macOS just inverts the template).
    dot_outer_r = max(3, round(size * 0.11))
    dot_inner_r = max(1, dot_outer_r - max(2, round(size * 0.035)))
    dot_cx = size - pad - dot_outer_r - max(1, round(size * 0.02))
    dot_cy = pad + dot_outer_r + max(1, round(size * 0.02))

    # Erase any frame strokes underneath the dot, then redraw the dot as a
    # ring. Use a small extra margin so the ring is cleanly isolated.
    isolate = dot_outer_r + max(2, round(size * 0.04))
    draw.ellipse(
        [(dot_cx - isolate, dot_cy - isolate),
         (dot_cx + isolate, dot_cy + isolate)],
        fill=(0, 0, 0, 0),
    )
    draw.ellipse(
        [(dot_cx - dot_outer_r, dot_cy - dot_outer_r),
         (dot_cx + dot_outer_r, dot_cy + dot_outer_r)],
        fill=BLACK,
    )
    draw.ellipse(
        [(dot_cx - dot_inner_r, dot_cy - dot_inner_r),
         (dot_cx + dot_inner_r, dot_cy + dot_inner_r)],
        fill=(0, 0, 0, 0),
    )
    return out


def write_status_bar_icon(icon: Image.Image) -> None:
    """Two sizes for retina menu bars; flat in Resources/ for NSImage(contentsOfFile:)."""
    icon.resize((22, 22), Image.LANCZOS).save(HERE / "status-bar.png", "PNG")
    icon.resize((44, 44), Image.LANCZOS).save(HERE / "status-bar@2x.png", "PNG")


if __name__ == "__main__":
    icon = make_icon(1024)
    write_appiconset(icon)
    write_ha_icon(icon)
    write_status_bar_icon(make_status_bar_icon(88))
    print(f"Wrote AppIcon.appiconset to {APPICON_DIR}")
    print(f"Wrote HA icons to {HA_ICON_DIR}")
    print(f"Wrote status-bar icons to {HERE}")
