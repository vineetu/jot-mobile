#!/usr/bin/env python3
from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


SIZES = [1024, 180, 120, 87, 80, 60, 58, 40, 29, 20]
FONT_PATH = Path("/System/Library/Fonts/NewYork.ttf")
COLORS = {
    "base": (0x0A, 0x0A, 0x0C),
    "white": (255, 255, 255),
    "black": (0, 0, 0),
    "coral": (0xFF, 0x6B, 0x57),
    "coral_dark": (0xE0, 0x53, 0x3F),
}
SUPERSAMPLE = 4
GLYPH = "\u0237"


SCRIPT_DIR = Path(__file__).resolve().parent
APP_ICON_DIR = SCRIPT_DIR.parent
RESOURCES_DIR = APP_ICON_DIR.parent
APPICONSET_DIR = RESOURCES_DIR / "Assets.xcassets" / "AppIcon.appiconset"
QA_DIR = APP_ICON_DIR / "qa"


def _resampling_lanczos():
    return getattr(getattr(Image, "Resampling", Image), "LANCZOS")


def _alpha_byte(alpha: float) -> int:
    return max(0, min(255, round(alpha * 255)))


def _mix_rgb(left: tuple[int, int, int], right: tuple[int, int, int], amount: float) -> tuple[int, int, int]:
    return tuple(round(left[i] + (right[i] - left[i]) * amount) for i in range(3))


def _lerp(left: float, right: float, amount: float) -> float:
    return left + (right - left) * amount


def _alpha_at_radius(radius: float, stops: tuple[tuple[float, float], ...]) -> float:
    if radius <= stops[0][0]:
        return stops[0][1]

    for index in range(1, len(stops)):
        previous_radius, previous_alpha = stops[index - 1]
        next_radius, next_alpha = stops[index]
        if radius <= next_radius:
            span = next_radius - previous_radius
            amount = 0.0 if span == 0 else (radius - previous_radius) / span
            return _lerp(previous_alpha, next_alpha, amount)

    return stops[-1][1]


def _alpha_composite_at(base: Image.Image, overlay: Image.Image, origin: tuple[int, int]) -> None:
    base.alpha_composite(overlay, origin)


def _add_radial_ellipse(
    tile: Image.Image,
    center: tuple[float, float],
    extent: tuple[float, float],
    rgb: tuple[int, int, int],
    stops: tuple[tuple[float, float], ...],
) -> None:
    width, height = tile.size
    center_x, center_y = center
    radius_x = extent[0] / 2.0
    radius_y = extent[1] / 2.0
    max_radius = stops[-1][0]

    left = max(0, math.floor(center_x - radius_x * max_radius))
    top = max(0, math.floor(center_y - radius_y * max_radius))
    right = min(width, math.ceil(center_x + radius_x * max_radius))
    bottom = min(height, math.ceil(center_y + radius_y * max_radius))
    crop_width = right - left
    crop_height = bottom - top
    if crop_width <= 0 or crop_height <= 0:
        return

    pixels = bytearray(crop_width * crop_height * 4)
    offset = 0
    for y in range(top, bottom):
        normalized_y = ((y + 0.5) - center_y) / radius_y
        normalized_y_squared = normalized_y * normalized_y
        for x in range(left, right):
            normalized_x = ((x + 0.5) - center_x) / radius_x
            radius = math.sqrt((normalized_x * normalized_x) + normalized_y_squared)
            alpha = _alpha_byte(_alpha_at_radius(radius, stops))
            pixels[offset] = rgb[0]
            pixels[offset + 1] = rgb[1]
            pixels[offset + 2] = rgb[2]
            pixels[offset + 3] = alpha
            offset += 4

    overlay = Image.frombytes("RGBA", (crop_width, crop_height), bytes(pixels))
    _alpha_composite_at(tile, overlay, (left, top))


def _add_top_hairline(tile: Image.Image, final_size: int, scale: int) -> None:
    width, _ = tile.size
    line_height = max(1, round(final_size / 1024)) * scale
    start_x = width * 0.08
    end_x = width * 0.92
    left = math.floor(start_x)
    right = math.ceil(end_x)
    crop_width = max(0, right - left)
    if crop_width == 0:
        return

    center_x = (start_x + end_x) / 2.0
    half_width = (end_x - start_x) / 2.0
    pixels = bytearray(crop_width * line_height * 4)
    offset = 0
    for _y in range(line_height):
        for x in range(left, right):
            distance = abs(((x + 0.5) - center_x) / half_width)
            alpha = _alpha_byte(0.45 * max(0.0, 1.0 - distance))
            pixels[offset] = 255
            pixels[offset + 1] = 255
            pixels[offset + 2] = 255
            pixels[offset + 3] = alpha
            offset += 4

    overlay = Image.frombytes("RGBA", (crop_width, line_height), bytes(pixels))
    _alpha_composite_at(tile, overlay, (left, 0))


def _add_inner_border(tile: Image.Image, final_size: int, scale: int) -> None:
    width, height = tile.size
    border_width = max(1, round(final_size / 1024)) * scale
    inset = border_width
    draw = ImageDraw.Draw(tile, "RGBA")
    draw.rectangle(
        [inset, inset, width - 1 - inset, height - 1 - inset],
        outline=(*COLORS["white"], _alpha_byte(0.06)),
        width=border_width,
    )


def _draw_glyph(tile: Image.Image, final_size: int, scale: int) -> None:
    size = final_size * scale
    font_size = round(size * 0.62)
    font = ImageFont.truetype(str(FONT_PATH), font_size)
    draw = ImageDraw.Draw(tile)
    draw.text(
        (size * (0.5 + 0.03), size * (0.5 - 0.06)),
        GLYPH,
        fill=(*COLORS["white"], 255),
        font=font,
        anchor="mm",
    )


def _add_coral_dot(tile: Image.Image, final_size: int, scale: int) -> None:
    size = final_size * scale
    diameter = size * 0.16
    radius = diameter / 2.0
    left = size * 0.46
    top = size * 0.16
    center_x = left + radius
    center_y = top + radius
    halo_thickness = size * 0.018
    halo_radius = radius + halo_thickness

    crop_left = max(0, math.floor(center_x - halo_radius))
    crop_top = max(0, math.floor(center_y - halo_radius))
    crop_right = min(size, math.ceil(center_x + halo_radius))
    crop_bottom = min(size, math.ceil(center_y + halo_radius))
    crop_width = crop_right - crop_left
    crop_height = crop_bottom - crop_top
    if crop_width <= 0 or crop_height <= 0:
        return

    halo_pixels = bytearray(crop_width * crop_height * 4)
    dot_pixels = bytearray(crop_width * crop_height * 4)
    highlight_rgb = _mix_rgb(COLORS["coral"], COLORS["white"], 0.30)
    halo_alpha = _alpha_byte(0.20)
    offset = 0

    for y in range(crop_top, crop_bottom):
        for x in range(crop_left, crop_right):
            pixel_x = x + 0.5
            pixel_y = y + 0.5
            dot_distance = math.hypot(pixel_x - center_x, pixel_y - center_y)

            if radius < dot_distance <= halo_radius:
                halo_pixels[offset] = COLORS["coral"][0]
                halo_pixels[offset + 1] = COLORS["coral"][1]
                halo_pixels[offset + 2] = COLORS["coral"][2]
                halo_pixels[offset + 3] = halo_alpha

            if dot_distance <= radius:
                gradient_x = left + diameter * 0.35
                gradient_y = top + diameter * 0.30
                gradient_radius = math.hypot(pixel_x - gradient_x, pixel_y - gradient_y) / radius
                if gradient_radius <= 0.50:
                    amount = gradient_radius / 0.50
                    rgb = _mix_rgb(highlight_rgb, COLORS["coral"], amount)
                else:
                    amount = min(1.0, (gradient_radius - 0.50) / 0.50)
                    rgb = _mix_rgb(COLORS["coral"], COLORS["coral_dark"], amount)

                dot_pixels[offset] = rgb[0]
                dot_pixels[offset + 1] = rgb[1]
                dot_pixels[offset + 2] = rgb[2]
                dot_pixels[offset + 3] = 255

            offset += 4

    halo_overlay = Image.frombytes("RGBA", (crop_width, crop_height), bytes(halo_pixels))
    dot_overlay = Image.frombytes("RGBA", (crop_width, crop_height), bytes(dot_pixels))
    _alpha_composite_at(tile, halo_overlay, (crop_left, crop_top))
    _alpha_composite_at(tile, dot_overlay, (crop_left, crop_top))

    highlight_width = max(1, round(final_size / 1024)) * scale
    draw = ImageDraw.Draw(tile, "RGBA")
    inset = highlight_width
    draw.arc(
        [left + inset, top + inset, left + diameter - inset, top + diameter - inset],
        205,
        335,
        fill=(*COLORS["white"], _alpha_byte(0.18)),
        width=highlight_width,
    )


def render_tile(final_size: int) -> Image.Image:
    scale = SUPERSAMPLE
    size = final_size * scale
    tile = Image.new("RGBA", (size, size), (*COLORS["base"], 255))

    _add_radial_ellipse(
        tile,
        center=(size * 0.28, size * 0.08),
        extent=(size * 0.90, size * 0.55),
        rgb=COLORS["white"],
        stops=((0.0, 0.22), (0.38, 0.04), (0.62, 0.0)),
    )
    _add_radial_ellipse(
        tile,
        center=(size * 0.70, size * 1.05),
        extent=(size * 0.75, size * 0.50),
        rgb=COLORS["black"],
        stops=((0.0, 0.55), (0.60, 0.0)),
    )
    _add_top_hairline(tile, final_size, scale)
    _add_inner_border(tile, final_size, scale)
    _draw_glyph(tile, final_size, scale)
    _add_coral_dot(tile, final_size, scale)

    return tile.resize((final_size, final_size), _resampling_lanczos()).convert("RGB")


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", compress_level=9)
    print(f"wrote {path}")


def main() -> None:
    if not FONT_PATH.exists():
        raise FileNotFoundError(f"Missing required font: {FONT_PATH}")

    QA_DIR.mkdir(parents=True, exist_ok=True)
    APPICONSET_DIR.mkdir(parents=True, exist_ok=True)

    for size in SIZES:
        image = render_tile(size)
        if size == 1024:
            save_png(image, APPICONSET_DIR / "icon-1024.png")
        save_png(image, QA_DIR / f"icon-{size}.png")


if __name__ == "__main__":
    main()
