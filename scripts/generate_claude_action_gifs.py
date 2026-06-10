from __future__ import annotations

import math
from pathlib import Path
from typing import Callable, Iterable

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "design" / "claude-gif-actions"
SIZE = 128
SCALE = 4
FPS_MS = 60
CLAUDE = (217, 119, 87)
CLAUDE_HI = (235, 147, 112)
INK = (8, 9, 14)
GREEN = (48, 209, 88)
CYAN = (100, 210, 255)
AMBER = (255, 180, 84)
PINK = (240, 164, 208)


def ease_sine(t: float) -> float:
    return 0.5 - 0.5 * math.cos(t * math.tau)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def draw_soft_circle(layer: Image.Image, cx: float, cy: float, r: float, color: tuple[int, int, int], alpha: int) -> None:
    d = ImageDraw.Draw(layer, "RGBA")
    steps = 8
    for i in range(steps, 0, -1):
        rr = r * i / steps
        aa = int(alpha * (i / steps) ** 2 / steps)
        d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=(*color, aa))


def icon_mask(
    size: int,
    body_scale: float = 1.0,
    bob: float = 0.0,
    tilt: float = 0.0,
    x_scale: float = 1.0,
    y_scale: float = 1.0,
) -> Image.Image:
    canvas = size * SCALE
    unit = canvas / 24.0 * body_scale
    center = canvas / 2
    xoff = canvas * (1 - body_scale) / 2
    yoff = canvas * (1 - body_scale) / 2 + bob * SCALE

    def xy(x: float, y: float) -> tuple[float, float]:
        px = xoff + x * unit
        py = yoff + y * unit
        return center + (px - center) * x_scale, center + (py - center) * y_scale

    mask = Image.new("L", (canvas, canvas), 0)
    d = ImageDraw.Draw(mask)

    def rr(box: tuple[float, float, float, float], radius: float, fill: int) -> None:
        d.rounded_rectangle(box, radius=radius * unit, fill=fill)

    rr((*xy(3, 5), *xy(21, 17.08)), 0.85, 255)
    rr((*xy(0, 10.95), *xy(3.1, 14.05)), 0.35, 255)
    rr((*xy(20.9, 10.95), *xy(24, 14.05)), 0.35, 255)
    for x1, x2 in [(4.49, 6), (7.49, 9), (15, 16.51), (18, 19.51)]:
        rr((*xy(x1, 16.85), *xy(x2, 20)), 0.25, 255)
    rr((*xy(6, 8.1), *xy(7.49, 10.95)), 0.18, 0)
    rr((*xy(16.51, 8.1), *xy(18, 10.95)), 0.18, 0)

    if abs(tilt) > 0.01:
        mask = mask.rotate(tilt, resample=Image.Resampling.BICUBIC, center=(canvas / 2, canvas / 2))
    return mask


def draw_icon(
    frame: Image.Image,
    *,
    scale: float = 0.72,
    bob: float = 0,
    tilt: float = 0,
    glow: float = 0.0,
    fill_shift: float = 0.0,
    x_scale: float = 1.0,
    y_scale: float = 1.0,
) -> None:
    layer_size = SIZE
    mask = icon_mask(layer_size, body_scale=scale, bob=bob, tilt=tilt, x_scale=x_scale, y_scale=y_scale)
    hi = tuple(int(lerp(CLAUDE[i], CLAUDE_HI[i], fill_shift)) for i in range(3))
    body = Image.new("RGBA", (layer_size * SCALE, layer_size * SCALE), (*hi, 255))

    if glow > 0:
        # GIF only supports binary transparency, so soft glows create dirty
        # matte edges in many renderers. Keep the parameter for experiments,
        # but deliberately skip glow in the production GIF export.
        pass

    icon = Image.composite(body, Image.new("RGBA", body.size), mask).resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    frame.alpha_composite(icon)


def star(draw: ImageDraw.ImageDraw, cx: float, cy: float, r: float, color: tuple[int, int, int], alpha: int) -> None:
    draw.line((cx - r, cy, cx + r, cy), fill=(*color, alpha), width=max(1, int(r / 5)))
    draw.line((cx, cy - r, cx, cy + r), fill=(*color, alpha), width=max(1, int(r / 5)))
    draw.ellipse((cx - 2, cy - 2, cx + 2, cy + 2), fill=(*color, alpha))


def save_gif(name: str, frames: Iterable[Image.Image], duration: int = FPS_MS) -> None:
    frames = [gif_safe(frame) for frame in frames]
    path = OUT / name
    frames[0].save(
        path,
        save_all=True,
        append_images=frames[1:],
        duration=duration,
        loop=0,
        disposal=2,
        transparency=0,
        optimize=False,
    )


def gif_safe(frame: Image.Image) -> Image.Image:
    """Remove partial-alpha pixels before GIF palette conversion.

    GIF transparency is on/off only. If we leave antialias or glow pixels as
    semi-transparent, Pillow/browser renderers often quantize them through a
    black matte. A hard alpha threshold is cleaner for a tiny sidebar/status
    icon, even if it is slightly less soft than PNG/APNG.
    """
    frame = frame.convert("RGBA")
    pixels = frame.load()
    w, h = frame.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a < 160:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (r, g, b, 255)
    return frame


def idle_frame(i: int, n: int) -> Image.Image:
    t = i / n
    breathe = ease_sine(t)
    frame = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_icon(frame, scale=0.70 + 0.018 * breathe, bob=math.sin(t * math.tau) * 1.0, glow=0, fill_shift=0.10 * breathe)
    d = ImageDraw.Draw(frame, "RGBA")
    r = 2.4 + 1.4 * breathe
    d.ellipse((95 - r, 34 - r, 95 + r, 34 + r), fill=(*AMBER, 255))
    return frame


def thinking_frame(i: int, n: int) -> Image.Image:
    t = i / n
    frame = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    wobble = math.sin(t * math.tau) * 2.5
    draw_icon(frame, scale=0.70, bob=math.sin(t * math.tau * 2) * 0.8, tilt=wobble, glow=0, fill_shift=0.08)
    d = ImageDraw.Draw(frame, "RGBA")
    for k in range(3):
        phase = (t + k / 3) % 1
        x = 44 + k * 18
        y = 27 - math.sin(phase * math.tau) * 5
        r = 2.0 + 1.4 * ease_sine(phase)
        d.ellipse((x - r, y - r, x + r, y + r), fill=(*AMBER, 255))
    return frame


def tool_frame(i: int, n: int) -> Image.Image:
    t = i / n
    frame = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_icon(frame, scale=0.70, bob=0, glow=0, fill_shift=0.05)
    d = ImageDraw.Draw(frame, "RGBA")
    sweep = 29 + 70 * t
    d.rounded_rectangle((sweep - 14, 42, sweep + 14, 46), radius=2, fill=(*CYAN, 255))
    for k in range(4):
        phase = (t + k / 4) % 1
        x = 26 + 76 * phase
        y = 89 + math.sin(phase * math.tau * 2) * 5
        d.line((x - 5, y, x + 5, y), fill=(*CYAN, 255), width=2)
        d.line((x, y - 5, x, y + 5), fill=(*CYAN, 255), width=1)
    return frame


def working_frame(i: int, n: int) -> Image.Image:
    t = i / n
    frame = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    stride = math.sin(t * math.tau * 2)
    lift = abs(stride)
    draw_icon(
        frame,
        scale=0.70,
        bob=-1.8 * lift,
        tilt=-5.0 + 2.0 * math.sin(t * math.tau),
        glow=0,
        fill_shift=0.06 + 0.10 * lift,
    )
    d = ImageDraw.Draw(frame, "RGBA")

    # Speed lines: enter from the right and reset, suggesting forward motion
    # while the icon stays anchored in its sidebar-sized frame.
    for k, y in enumerate((42, 56, 74)):
        phase = (t * 2.2 + k * 0.23) % 1
        x = 98 - phase * 28
        length = 9 + 4 * (1 - phase)
        alpha = int(210 * (1 - phase))
        d.line((x, y, x + length, y), fill=(*CYAN, max(0, alpha)), width=2)

    # Alternating feet are tiny and geometric to match the existing mascot.
    foot_y = 99
    d.line((45, foot_y, 45 + 8 * max(0, stride), foot_y + 5), fill=(*CLAUDE, 255), width=3)
    d.line((62, foot_y, 62 + 8 * max(0, -stride), foot_y + 5), fill=(*CLAUDE, 255), width=3)

    # Small amber work pulse.
    pulse = ease_sine((t * 2) % 1)
    r = 2.2 + 1.2 * pulse
    d.ellipse((29 - r, 39 - r, 29 + r, 39 + r), fill=(*AMBER, 255))
    return frame


def compressing_frame(i: int, n: int) -> Image.Image:
    t = i / n
    frame = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    squeeze = ease_sine((t * 2) % 1)
    x_scale = 1.0 + 0.075 * squeeze
    y_scale = 1.0 - 0.115 * squeeze
    draw_icon(
        frame,
        scale=0.70,
        bob=1.5 * squeeze,
        tilt=0,
        glow=0,
        fill_shift=0.08 * squeeze,
        x_scale=x_scale,
        y_scale=y_scale,
    )
    d = ImageDraw.Draw(frame, "RGBA")

    # Compression plates move inward, then release.
    top_y = 27 + 9 * squeeze
    bottom_y = 101 - 9 * squeeze
    d.rounded_rectangle((35, top_y, 93, top_y + 4), radius=2, fill=(*CYAN, 255))
    d.rounded_rectangle((35, bottom_y, 93, bottom_y + 4), radius=2, fill=(*CYAN, 255))

    # Tiny stacked archive bars inside the mascot read as "packing".
    bar_alpha = 255
    for k in range(3):
        w = 18 - 3 * k
        x = 64 - w / 2
        y = 52 + k * 8 + 2 * math.sin(t * math.tau + k)
        d.rounded_rectangle((x, y, x + w, y + 3), radius=1.4, fill=(*AMBER, bar_alpha))

    # Inward side ticks.
    shift = 7 * squeeze
    d.line((31 + shift, 62, 42 + shift, 62), fill=(*PINK, 255), width=2)
    d.line((97 - shift, 62, 86 - shift, 62), fill=(*PINK, 255), width=2)
    return frame


def complete_frame(i: int, n: int) -> Image.Image:
    t = i / n
    pop = min(1.0, t * 3.4)
    settle = 1 + 0.035 * math.sin(min(1, t * 2.2) * math.pi) * (1 - min(1, max(0, (t - 0.45) / 0.55)))
    frame = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_icon(frame, scale=0.70 * settle, bob=-1.2 * math.sin(min(1, t * 2) * math.pi), glow=0, fill_shift=0.18 * ease_sine(pop))
    d = ImageDraw.Draw(frame, "RGBA")

    # Completion reads as a short celebratory glint, not as a badge.
    if 0.02 < t < 0.55:
        phase = (t - 0.02) / 0.53
        a = int(255 * math.sin(phase * math.pi))
        star(d, 38, 35, 6 + 8 * phase, PINK, a)
        star(d, 97, 34, 5 + 7 * phase, AMBER, int(a * 0.9))
        d.arc((28, 28, 100, 100), start=205, end=205 + 230 * phase, fill=(*GREEN, int(a * 0.72)), width=3)

    if 0.28 < t < 0.92:
        phase = (t - 0.28) / 0.64
        a = int(210 * (1 - phase))
        y = 89 + 2 * math.sin(phase * math.tau)
        d.line((34, y, 94, y), fill=(*GREEN, max(0, a)), width=2)
    return frame


def make_preview_sheet(samples: dict[str, Image.Image]) -> None:
    cell = 170
    sheet = Image.new("RGBA", (cell * 4, 190), (8, 9, 14, 255))
    d = ImageDraw.Draw(sheet, "RGBA")
    for idx, (name, image) in enumerate(samples.items()):
        x = idx * cell
        d.rounded_rectangle((x + 14, 12, x + cell - 14, 154), radius=8, fill=(255, 255, 255, 10), outline=(255, 255, 255, 18))
        sheet.alpha_composite(image, (x + 21, 19))
        d.text((x + 16, 164), name, fill=(184, 185, 200, 255))
    sheet.convert("RGB").save(OUT / "contact-sheet.png")


def make_preview_html() -> None:
    html = """<!doctype html>
<html lang=\"zh-CN\">
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>Claude Action GIFs</title>
  <style>
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #070811; color: #ececf4; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif; }
    .grid { display: grid; grid-template-columns: repeat(6, 160px); gap: 18px; }
    .item { height: 188px; border: 1px solid rgba(255,255,255,.07); border-radius: 10px; background: linear-gradient(180deg, rgba(255,255,255,.05), rgba(255,255,255,.02)); display: grid; place-items: center; padding: 12px; box-shadow: inset 0 1px 0 rgba(255,255,255,.06); }
    img { width: 128px; height: 128px; image-rendering: auto; }
    span { color: #9ca0b5; font-size: 12px; font-weight: 600; }
  </style>
</head>
<body>
  <div class=\"grid\">
    <div class=\"item\"><img src=\"claude-idle.gif\"><span>idle</span></div>
    <div class=\"item\"><img src=\"claude-thinking.gif\"><span>thinking</span></div>
    <div class=\"item\"><img src=\"claude-tool-call.gif\"><span>tool call</span></div>
    <div class=\"item\"><img src=\"claude-working.gif\"><span>working</span></div>
    <div class=\"item\"><img src=\"claude-compressing.gif\"><span>compressing</span></div>
    <div class=\"item\"><img src=\"claude-complete.gif\"><span>complete</span></div>
  </div>
</body>
</html>
"""
    (OUT / "preview.html").write_text(html, encoding="utf-8")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    frame_count = 40
    animations: dict[str, Callable[[int, int], Image.Image]] = {
        "claude-idle.gif": idle_frame,
        "claude-thinking.gif": thinking_frame,
        "claude-tool-call.gif": tool_frame,
        "claude-working.gif": working_frame,
        "claude-compressing.gif": compressing_frame,
        "claude-complete.gif": complete_frame,
    }
    for filename, factory in animations.items():
        save_gif(filename, (factory(i, frame_count) for i in range(frame_count)))
    make_preview_sheet({
        "idle": idle_frame(10, frame_count),
        "thinking": thinking_frame(16, frame_count),
        "tool call": tool_frame(22, frame_count),
        "working": working_frame(14, frame_count),
        "compressing": compressing_frame(10, frame_count),
        "complete": complete_frame(22, frame_count),
    })
    make_preview_html()


if __name__ == "__main__":
    main()
