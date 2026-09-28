#!/usr/bin/env python3
"""Builds the AutoLoom Media Glasses iOS brand assets from the source logo.

Source: assets/brand/LOGO 2.png (white "AL" monogram on black, kept unchanged).
Outputs (asset catalog):
  AppIcon.appiconset      1024 px icon + dark + tinted variants (opaque)
  BrandMark.imageset      the mark alone, white on transparent
  LaunchMark.imageset     the mark for the launch screen (@3x)
  LaunchBackground.colorset
Run from the repository root: python scripts/make-brand-assets.py
"""
import json
import pathlib

import numpy as np
from PIL import Image, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "brand" / "LOGO 2.png"
CATALOG = ROOT / "ios" / "GlassifAI" / "Assets.xcassets"

NAVY_TOP = np.array([11, 22, 46], dtype=np.float32)       # deep navy
NAVY_BOTTOM = np.array([2, 5, 13], dtype=np.float32)      # near black
ELECTRIC_BLUE = np.array([26, 143, 255], dtype=np.float32)
WHITE = np.array([255, 255, 255], dtype=np.float32)
SILVER = np.array([196, 206, 222], dtype=np.float32)


def extract_mark(source: Image.Image) -> Image.Image:
    """White strokes on black -> alpha from luminance, cropped to the mark."""
    gray = np.asarray(source.convert("L"), dtype=np.float32)
    # Clean the black background and keep anti-aliased edges.
    alpha = np.clip((gray - 18.0) / (235.0 - 18.0), 0.0, 1.0)
    ys, xs = np.nonzero(alpha > 0.02)
    top, bottom, left, right = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    alpha = alpha[top:bottom, left:right]
    rgba = np.zeros((alpha.shape[0], alpha.shape[1], 4), dtype=np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = (alpha * 255.0 + 0.5).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def fit(mark: Image.Image, width: int) -> Image.Image:
    height = round(mark.height * width / mark.width)
    return mark.resize((width, height), Image.LANCZOS)


def vertical_gradient(size: int, top: np.ndarray, bottom: np.ndarray) -> np.ndarray:
    t = np.linspace(0.0, 1.0, size, dtype=np.float32)[:, None, None]
    column = top * (1.0 - t) + bottom * t
    return np.repeat(column, size, axis=1)


def radial_glow(size: int, center: tuple, radius: float, strength: float) -> np.ndarray:
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    distance = np.sqrt((xx - center[0]) ** 2 + (yy - center[1]) ** 2) / radius
    return (np.exp(-(distance ** 2) * 2.2) * strength)[..., None]


def composite(background: np.ndarray, mark: Image.Image, offset: tuple, colors: np.ndarray) -> np.ndarray:
    """Places the mark (alpha) filled with a per-pixel colour array."""
    out = background.copy()
    alpha = np.asarray(mark, dtype=np.float32)[..., 3:4] / 255.0
    x, y = offset
    h, w = alpha.shape[:2]
    region = out[y:y + h, x:x + w]
    out[y:y + h, x:x + w] = region * (1.0 - alpha) + colors[:h, :w] * alpha
    return out


def mark_fill(height: int, width: int, top: np.ndarray, bottom: np.ndarray) -> np.ndarray:
    t = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None, None]
    column = top * (1.0 - t) + bottom * t
    return np.repeat(column, width, axis=1)


def save_rgb(array: np.ndarray, path: pathlib.Path) -> None:
    Image.fromarray(np.clip(array + 0.5, 0, 255).astype(np.uint8), "RGB").save(path, optimize=True)


def build_icon(mark: Image.Image, tinted: bool = False) -> np.ndarray:
    size = 1024
    icon_mark = fit(mark, 600)
    x = (size - icon_mark.width) // 2
    y = (size - icon_mark.height) // 2 + 6
    if tinted:
        # Tinted variant: grayscale artwork the system colours.
        background = np.zeros((size, size, 3), dtype=np.float32)
        fill = mark_fill(icon_mark.height, icon_mark.width, WHITE, WHITE * 0.86)
        return composite(background, icon_mark, (x, y), fill)
    background = vertical_gradient(size, NAVY_TOP, NAVY_BOTTOM)
    # Restrained electric-blue light under the mark (no neon).
    glow = radial_glow(size, (size / 2, size * 0.58), size * 0.42, 0.34)
    background = background * (1.0 - glow) + ELECTRIC_BLUE * glow
    # Soft blue shadow for depth.
    shadow = Image.new("L", (size, size), 0)
    shadow.paste(icon_mark.getchannel("A"), (x, y + 10))
    shadow = np.asarray(shadow.filter(ImageFilter.GaussianBlur(22)), dtype=np.float32)[..., None] / 255.0 * 0.55
    background = background * (1.0 - shadow) + (ELECTRIC_BLUE * 0.45) * shadow
    fill = mark_fill(icon_mark.height, icon_mark.width, WHITE, SILVER)
    icon = composite(background, icon_mark, (x, y), fill)
    # Thin electric-blue baseline accent under the mark.
    line_y = y + icon_mark.height + 44
    line = np.zeros((size, size, 1), dtype=np.float32)
    half = 120
    line[line_y:line_y + 5, size // 2 - half:size // 2 + half] = 1.0
    fade = np.abs(np.linspace(-1.0, 1.0, 2 * half, dtype=np.float32))
    line[line_y:line_y + 5, size // 2 - half:size // 2 + half, 0] *= (1.0 - fade ** 2)[None, :]
    icon = icon * (1.0 - line * 0.9) + ELECTRIC_BLUE * line * 0.9
    return icon


def write_json(path: pathlib.Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    source = Image.open(SOURCE)
    mark = extract_mark(source)

    icon_dir = CATALOG / "AppIcon.appiconset"
    for old in icon_dir.glob("*.png"):
        old.unlink()
    save_rgb(build_icon(mark), icon_dir / "AutoLoomAppIcon.png")
    save_rgb(build_icon(mark), icon_dir / "AutoLoomAppIcon-Dark.png")
    save_rgb(build_icon(mark, tinted=True), icon_dir / "AutoLoomAppIcon-Tinted.png")
    write_json(icon_dir / "Contents.json", {
        "images": [
            {"filename": "AutoLoomAppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "filename": "AutoLoomAppIcon-Dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
             "filename": "AutoLoomAppIcon-Tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    })

    brand_dir = CATALOG / "BrandMark.imageset"
    fit(mark, 900).save(brand_dir / "BrandMark.png", optimize=True)
    write_json(brand_dir / "Contents.json", {
        "images": [{"filename": "BrandMark.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": False},
    })

    launch_dir = CATALOG / "LaunchMark.imageset"
    launch_dir.mkdir(exist_ok=True)
    fit(mark, 540).save(launch_dir / "LaunchMark@3x.png", optimize=True)  # 180 pt wide
    write_json(launch_dir / "Contents.json", {
        "images": [
            {"idiom": "universal", "scale": "1x"},
            {"idiom": "universal", "scale": "2x"},
            {"filename": "LaunchMark@3x.png", "idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    })

    color_dir = CATALOG / "LaunchBackground.colorset"
    color_dir.mkdir(exist_ok=True)
    write_json(color_dir / "Contents.json", {
        "colors": [{
            "color": {"color-space": "srgb", "components": {
                "red": f"{NAVY_BOTTOM[0] / 255:.3f}", "green": f"{NAVY_BOTTOM[1] / 255:.3f}",
                "blue": f"{NAVY_BOTTOM[2] / 255:.3f}", "alpha": "1.000"}},
            "idiom": "universal",
        }],
        "info": {"author": "xcode", "version": 1},
    })
    print("mark", mark.size, "-> assets written")


if __name__ == "__main__":
    main()
