#!/usr/bin/env python3
"""Turn a flat square artwork into a macOS-ready app icon set (.icns) and a Windows .ico.

Usage:
    python3 build_icons.py <source.png> <out_dir> [--name AppIcon]

Layout follows the macOS Big Sur+ icon grid: 1024 canvas, 824x824 icon body
centred (100px margin), squircle corner radius ~22.5% of the body width.
The area outside the squircle stays transparent so Finder/Dock can draw
its own shadow.
"""

import argparse
import os
import shutil
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
BODY = 824
MARGIN = (CANVAS - BODY) // 2
RADIUS_RATIO = 0.225
SQUIRCLE_N = 5.0

PNG_SIZES = [512, 256, 128, 64, 32, 16]
ICO_SIZES = [256, 128, 64, 48, 32, 24, 16]
ICONSET = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def squircle_mask(size: int, ss: int = 4) -> Image.Image:
    """Anti-aliased superellipse mask, |x|^n + |y|^n <= 1."""
    big = size * ss
    coords = (np.arange(big) + 0.5) / big * 2.0 - 1.0
    x = coords[None, :]
    y = coords[:, None]
    inside = (np.abs(x) ** SQUIRCLE_N + np.abs(y) ** SQUIRCLE_N) <= 1.0
    img = Image.fromarray((inside * 255).astype(np.uint8))
    return img.resize((size, size), Image.LANCZOS)


def tighten(src: Image.Image, threshold: int = 40, pad: float = 0.08) -> Image.Image:
    """Crop to the bright content bbox, re-centre it, and pad evenly.

    The content ends up filling 1/(1+2*pad) of the frame, so the icon body
    sits at a consistent optical size regardless of how much empty space the
    generated artwork shipped with.
    """
    lum = np.asarray(src.convert("L"), dtype=np.int16)
    border = np.concatenate([lum[0, :], lum[-1, :], lum[:, 0], lum[:, -1]])
    bg = int(np.median(border))
    mask = lum > bg + threshold
    if not mask.any():
        return src
    ys, xs = np.where(mask)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()

    extent = max(x1 - x0, y1 - y0)
    side = int(round(extent * (1 + 2 * pad)))
    cx = int(round((x0 + x1) / 2))
    cy = int(round((y0 + y1) / 2))
    left = cx - side // 2
    top = cy - side // 2

    arr = np.asarray(src.convert("RGB"))
    pad_l, pad_t = max(0, -left), max(0, -top)
    pad_r = max(0, left + side - src.width)
    pad_b = max(0, top + side - src.height)
    arr = np.pad(arr, ((pad_t, pad_b), (pad_l, pad_r), (0, 0)), mode="edge")
    arr = arr[top + pad_t:top + pad_t + side, left + pad_l:left + pad_l + side]
    return Image.fromarray(arr).resize(src.size, Image.LANCZOS)


def build_body(src: Image.Image, do_recenter: bool = False) -> Image.Image:
    if do_recenter:
        src = tighten(src)
    art = src.convert("RGB").resize((BODY, BODY), Image.LANCZOS)
    body = art.convert("RGBA")
    body.putalpha(squircle_mask(BODY))
    return body


def compose_canvas(body: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(body, (MARGIN, MARGIN), body)
    return canvas


def with_shadow(master: Image.Image, bg=(236, 238, 241)) -> Image.Image:
    pad = 0
    shadow = Image.new("RGBA", master.size, (0, 0, 0, 0))
    alpha = master.getchannel("A").filter(ImageFilter.GaussianBlur(18))
    shadow.putalpha(alpha.point(lambda v: int(v * 0.42)))
    out = Image.new("RGB", (master.width + pad, master.height + pad), bg)
    out.paste(shadow, (0, 8), shadow)
    out.paste(master, (0, 0), master)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("out_dir")
    ap.add_argument("--name", default="AppIcon")
    ap.add_argument("--recenter", action="store_true",
                    help="re-centre the artwork by its bright content bounding box")
    args = ap.parse_args()

    src = Image.open(args.source)
    out = os.path.abspath(args.out_dir)
    png_dir = os.path.join(out, "png")
    os.makedirs(png_dir, exist_ok=True)

    master = compose_canvas(build_body(src, args.recenter))
    master_path = os.path.join(out, f"{args.name}-1024.png")
    master.save(master_path)

    for size in PNG_SIZES:
        master.resize((size, size), Image.LANCZOS).save(
            os.path.join(png_dir, f"{args.name}-{size}.png")
        )

    # macOS .icns
    iconset = os.path.join(out, f"{args.name}.iconset")
    if os.path.isdir(iconset):
        shutil.rmtree(iconset)
    os.makedirs(iconset)
    for fname, size in ICONSET:
        master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, fname))
    icns_path = os.path.join(out, f"{args.name}.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns_path], check=True)
    shutil.rmtree(iconset)

    # Windows .ico
    ico_path = os.path.join(out, f"{args.name}.ico")
    master.save(ico_path, format="ICO", sizes=[(s, s) for s in ICO_SIZES])

    with_shadow(master).save(os.path.join(out, f"{args.name}-preview.png"))

    print(f"master   {master_path}")
    print(f"icns     {icns_path}")
    print(f"ico      {ico_path}")
    print(f"png set  {png_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
