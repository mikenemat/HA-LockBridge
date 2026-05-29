#!/usr/bin/env python3
"""Compose raw app-window grabs into App-Store-ready Mac screenshots.

The Mac App Store requires screenshots at *exact* pixel dimensions. A raw
window grab (Cmd-Shift-4, then Space, then click the window) is the wrong size
and carries a transparent margin + native shadow, so App Store Connect rejects
it outright. This script centers each grab on a correctly-sized canvas
(2560x1600 — a valid Mac screenshot size, 16:10, retina-crisp), lays it over a
clean gradient, adds an optional marketing caption, and flattens to opaque RGB.

Workflow:
    1. Run HA-LockBridge and open the window/state you want to capture:
         - the "Waiting for Home Assistant to pair" view
         - the pair-request Approve/Deny view
         - the Stats & Debug view (locks + live HA-connected indicator)
    2. Cmd-Shift-4, press Space, click the window. macOS saves a PNG to your
       Desktop (with transparency + shadow — that's fine, we use it).
    3. Drop those PNGs into  macos-app/Resources/screenshots/raw/
    4. (optional) add a headline per file in the CAPTIONS dict below.
    5. python3 Resources/make_appstore_screenshots.py
    6. Upload everything from  macos-app/Resources/screenshots/appstore/
       in App Store Connect (1-10 screenshots; order = display order).

Requires Pillow (already a project dependency; see generate_icon.py).
"""

from __future__ import annotations  # allow `str | None` hints on Python 3.9

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# 2560x1600 is a valid Mac App Store screenshot size (16:10). Retina-sharp and
# accepted for Mac Catalyst apps. Do not change unless you cross-check Apple's
# current "Mac" screenshot specification.
CANVAS_W, CANVAS_H = 2560, 1600

HERE = Path(__file__).resolve().parent
RAW_DIR = HERE / "screenshots" / "raw"
OUT_DIR = HERE / "screenshots" / "appstore"

# Optional headline per raw filename (filename only, no directory). Files not
# listed here render with no caption (just the window on the gradient). Keep
# these short — one line — they render large near the top.
CAPTIONS = {
    # "01-waiting.png":  "Your Apple Home locks, now in Home Assistant",
    # "02-pairing.png":  "Approve Home Assistant with one tap",
    # "03-status.png":   "Live status for every lock — all on your LAN",
}

# Vertical background gradient (top RGB -> bottom RGB).
BG_TOP = (28, 38, 58)
BG_BOTTOM = (10, 14, 24)

CAPTION_RGB = (236, 240, 248)

# Fraction of the canvas the window art may occupy. Leaves headroom for the
# caption band at the top.
MAX_WIN_FRAC_W = 0.74
MAX_WIN_FRAC_H = 0.70
CAPTION_BAND_H = 220  # px reserved at top when a caption is present


def vertical_gradient(w: int, h: int, top: tuple, bottom: tuple) -> Image.Image:
    """Fast gradient: paint a 1px-wide column, then stretch to width."""
    col = Image.new("RGB", (1, h))
    px = col.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        px[0, y] = (
            round(top[0] + (bottom[0] - top[0]) * t),
            round(top[1] + (bottom[1] - top[1]) * t),
            round(top[2] + (bottom[2] - top[2]) * t),
        )
    return col.resize((w, h))


def load_font(size: int) -> ImageFont.FreeTypeFont:
    """Best-effort system font; falls back to Pillow's bundled font."""
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial Bold.ttf",
        "/System/Library/Fonts/SFNS.ttf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def fit_caption(draw: ImageDraw.ImageDraw, text: str, max_w: int) -> ImageFont.FreeTypeFont:
    """Shrink the font until the caption fits on one line within max_w."""
    size = 92
    while size > 40:
        font = load_font(size)
        w = draw.textbbox((0, 0), text, font=font)[2]
        if w <= max_w:
            return font
        size -= 4
    return load_font(40)


def compose(raw_path: Path, caption: str | None) -> Image.Image:
    canvas = vertical_gradient(CANVAS_W, CANVAS_H, BG_TOP, BG_BOTTOM).convert("RGBA")

    win = Image.open(raw_path)
    if win.mode != "RGBA":
        win = win.convert("RGBA")

    has_caption = bool(caption)
    avail_h = CANVAS_H - (CAPTION_BAND_H if has_caption else 0)
    max_w = int(CANVAS_W * MAX_WIN_FRAC_W)
    max_h = int(avail_h * (MAX_WIN_FRAC_H if not has_caption else 0.92))

    scale = min(max_w / win.width, max_h / win.height)
    new_size = (max(1, round(win.width * scale)), max(1, round(win.height * scale)))
    win = win.resize(new_size, Image.LANCZOS)

    # Horizontal center; vertical center within the area below the caption band.
    x = (CANVAS_W - win.width) // 2
    top_band = CAPTION_BAND_H if has_caption else 0
    y = top_band + (CANVAS_H - top_band - win.height) // 2

    # The native grab already carries a soft shadow in its alpha. Composite
    # directly so rounded corners + shadow read correctly over the gradient.
    canvas.alpha_composite(win, (x, y))

    if has_caption:
        draw = ImageDraw.Draw(canvas)
        font = fit_caption(draw, caption, int(CANVAS_W * 0.86))
        bbox = draw.textbbox((0, 0), caption, font=font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        tx = (CANVAS_W - tw) // 2 - bbox[0]
        ty = (CAPTION_BAND_H - th) // 2 - bbox[1]
        draw.text((tx, ty), caption, font=font, fill=CAPTION_RGB)

    return canvas.convert("RGB")  # flatten alpha; App Store wants opaque RGB


def main() -> None:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    raws = sorted(p for p in RAW_DIR.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg"})
    if not raws:
        print(f"No images found in {RAW_DIR}")
        print("Drop your window grabs there, then re-run. See this file's docstring.")
        return

    for raw in raws:
        out = OUT_DIR / f"{raw.stem}.png"
        compose(raw, CAPTIONS.get(raw.name)).save(out, "PNG")
        cap = CAPTIONS.get(raw.name)
        print(f"  {raw.name}  ->  {out.name}   {CANVAS_W}x{CANVAS_H}" + (f'   "{cap}"' if cap else ""))

    print(f"\nDone. {len(raws)} screenshot(s) in {OUT_DIR}")
    print("Upload them in App Store Connect under the 0.5.0 version > App Previews and Screenshots > Mac.")


if __name__ == "__main__":
    main()
