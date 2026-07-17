"""Generate Grok sidebar / tab mascot assets from the xAI chrome-X logo.

Input: a black-or-light-matte photo of the metallic X (default:
design/grok-src/Grok-Logo-xAI-Futuristic-AI.png). We soft-key the matte,
invert the body to a light silver suitable for Glint's dark chrome, and
render per-status APNGs + a static mark imageset.

States (match OpenCode / Devin / OMP mapping):
  idle / done / failed / needsPermission  -> static (or tinted static)
  thinking                                -> sway + breathe  (looping)
  tool                                    -> pulse + glint   (looping)
  compacting                              -> slow spin       (looping)

Usage:
  python3 scripts/generate_grok_action_gifs.py
  python3 scripts/generate_grok_action_gifs.py --preview   # contact sheet
  python3 scripts/generate_grok_action_gifs.py --install   # write into Assets.xcassets
"""

from __future__ import annotations

import json
import math
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SRC_DEFAULT = ROOT / "design" / "grok-src" / "Grok-Logo-xAI-Futuristic-AI.png"
OUT = ROOT / "design" / "grok-apng-actions"
ASSETS = ROOT / "Glint" / "Resources" / "Assets.xcassets"

SIZE = 128
FPS_MS = 50
LOOP = 40  # 2.0s seamless loop — leaner than Codex's 120f

# Tints for terminal states (applied as multiply-ish recolor of the silver X).
TINTS = {
    "idle": None,  # native silver
    "done": (0x40, 0xDC, 0x8C),
    "failed": (0xF5, 0x5C, 0x57),
    "needsPermission": (0xFF, 0xB0, 0x54),
}


def load_source(path: Path) -> Image.Image:
    if not path.exists():
        # Fall back to any Grok-Logo-xAI*.png/.webp under design/grok-src.
        candidates = sorted((ROOT / "design" / "grok-src").glob("Grok-Logo-xAI*"))
        candidates = [c for c in candidates if c.suffix.lower() in {".png", ".webp"}]
        if not candidates:
            raise SystemExit(f"source logo not found: {path}")
        path = candidates[0]
        print(f"using fallback source {path}")
    return Image.open(path).convert("RGBA")


def extract_mark(src: Image.Image) -> Image.Image:
    """Soft-key the matte and invert the body to a light silver X."""
    a = np.array(src).astype(np.float32)
    lum = a[:, :, 0] * 0.299 + a[:, :, 1] * 0.587 + a[:, :, 2] * 0.114

    # Soft alpha: body is the darker metal; matte is bright gray/white.
    alpha = np.clip((215.0 - lum) / 55.0, 0.0, 1.0)
    alpha = np.where(lum > 235.0, 0.0, alpha)

    # Invert + lift so the chrome X reads as light silver on dark chrome.
    inv = 255.0 - lum
    silver = np.clip(inv * 1.18 + 28.0, 0.0, 255.0)

    out = np.zeros_like(a)
    out[:, :, 0] = silver
    out[:, :, 1] = silver
    out[:, :, 2] = silver
    out[:, :, 3] = alpha * 255.0
    out[alpha <= 0.02] = 0

    img = Image.fromarray(out.astype(np.uint8), "RGBA")
    bb = img.getbbox()
    if bb is None:
        raise SystemExit("extraction produced empty mark — check source logo")
    cropped = img.crop(bb)

    # Square pad.
    s = max(cropped.size)
    sq = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sq.paste(cropped, ((s - cropped.size[0]) // 2, (s - cropped.size[1]) // 2), cropped)

    # Slight unsharp so the diagonals hold at 28pt.
    sq = sq.filter(ImageFilter.UnsharpMask(radius=1.2, percent=120, threshold=2))
    return sq


def fit_on_canvas(mark: Image.Image, size: int = SIZE, margin: float = 0.14) -> Image.Image:
    pad = int(size * margin)
    inner = size - 2 * pad
    scaled = mark.resize((inner, inner), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(scaled, (pad, pad), scaled)
    return canvas


def tint(mark: Image.Image, rgb: tuple[int, int, int] | None) -> Image.Image:
    if rgb is None:
        return mark
    a = np.array(mark).astype(np.float32)
    # Preserve relative luminance of the silver, multiply by tint.
    lum = (a[:, :, 0] * 0.299 + a[:, :, 1] * 0.587 + a[:, :, 2] * 0.114) / 255.0
    for i in range(3):
        a[:, :, i] = np.clip(lum * rgb[i], 0, 255)
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def transform(
    mark: Image.Image,
    *,
    rotation_deg: float = 0.0,
    scale: float = 1.0,
    dx: float = 0.0,
    dy: float = 0.0,
    opacity: float = 1.0,
) -> Image.Image:
    """Affine transform around canvas center, then re-center on SIZE canvas."""
    size = mark.size[0]
    img = mark
    if abs(rotation_deg) > 0.01:
        img = img.rotate(-rotation_deg, resample=Image.BICUBIC, center=(size / 2, size / 2))
    if abs(scale - 1.0) > 0.001:
        new = max(1, int(round(size * scale)))
        scaled = img.resize((new, new), Image.LANCZOS)
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        canvas.paste(scaled, ((size - new) // 2, (size - new) // 2), scaled)
        img = canvas
    if abs(dx) > 0.01 or abs(dy) > 0.01:
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        canvas.paste(img, (int(round(dx)), int(round(dy))), img)
        img = canvas
    if opacity < 0.999:
        a = np.array(img).astype(np.float32)
        a[:, :, 3] = np.clip(a[:, :, 3] * opacity, 0, 255)
        img = Image.fromarray(a.astype(np.uint8), "RGBA")
    return img


def frame_params(state: str, f: int) -> dict:
    t = (f % LOOP) / LOOP
    if state == "thinking":
        # Gentle sway + breathe — readable at 28pt, not dizzy.
        return {
            "rotation_deg": math.sin(t * math.tau) * 8.0,
            "scale": 1.0 + 0.05 * math.sin(t * math.pi * 2),
            "dx": math.sin(t * math.tau) * 1.5,
            "dy": math.cos(t * math.tau) * 1.0,
            "opacity": 1.0,
        }
    if state == "tool":
        # Pulse + brief highlight flash twice per loop.
        pulse = 0.5 + 0.5 * math.sin(t * math.pi * 4)
        flash = 1.0 if (f % (LOOP // 2)) < 3 else 0.0
        return {
            "rotation_deg": 0.0,
            "scale": 1.0 + 0.07 * pulse + 0.04 * flash,
            "dx": 0.0,
            "dy": 0.0,
            "opacity": 0.78 + 0.22 * pulse,
        }
    if state == "compacting":
        return {
            "rotation_deg": t * 360.0,
            "scale": 0.92 + 0.04 * math.sin(t * math.pi * 2),
            "dx": 0.0,
            "dy": 0.0,
            "opacity": 0.9,
        }
    return {"rotation_deg": 0.0, "scale": 1.0, "dx": 0.0, "dy": 0.0, "opacity": 1.0}


def render_frame(base: Image.Image, state: str, f: int) -> Image.Image:
    tinted = tint(base, TINTS.get(state))
    return transform(tinted, **frame_params(state, f))


def write_apng(frames: list[Image.Image], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        path,
        save_all=True,
        append_images=frames[1:],
        duration=FPS_MS,
        loop=0,
        disposal=1,
        blend=0,
    )
    print(f"wrote {path} ({len(frames)} frames, {path.stat().st_size // 1024}KB)")


def write_static(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG")
    print(f"wrote {path} (static)")


def dataset_contents(filename: str) -> dict:
    return {
        "data": [{"filename": filename, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }


def imageset_contents(f1: str, f2: str) -> dict:
    return {
        "images": [
            {"filename": f1, "idiom": "universal", "scale": "1x"},
            {"filename": f2, "idiom": "universal", "scale": "2x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }


def install_into_assets(out: Path) -> None:
    """Copy generated files into Assets.xcassets with Contents.json."""
    mapping = {
        "GrokIdle": "grok-idle.png",
        "GrokThinking": "grok-thinking.png",
        "GrokToolCall": "grok-tool-call.png",
        "GrokCompressing": "grok-compressing.png",
        "GrokDone": "grok-done.png",
        "GrokFailed": "grok-failed.png",
        "GrokNeedsPermission": "grok-needs-permission.png",
    }
    for asset, filename in mapping.items():
        src = out / filename
        if not src.exists():
            print(f"skip missing {src}")
            continue
        dest_dir = ASSETS / f"{asset}.dataset"
        if dest_dir.exists():
            shutil.rmtree(dest_dir)
        dest_dir.mkdir(parents=True)
        shutil.copy2(src, dest_dir / filename)
        (dest_dir / "Contents.json").write_text(
            json.dumps(dataset_contents(filename), indent=2) + "\n"
        )
        print(f"installed {dest_dir.name}")

    # Static mark for chooser / micro icon.
    mark_src = out / "grok-mark-48.png"
    mark24 = out / "grok-mark-24.png"
    if mark_src.exists() and mark24.exists():
        dest_dir = ASSETS / "GrokMark.imageset"
        if dest_dir.exists():
            shutil.rmtree(dest_dir)
        dest_dir.mkdir(parents=True)
        shutil.copy2(mark24, dest_dir / "grok24.png")
        shutil.copy2(mark_src, dest_dir / "grok48.png")
        (dest_dir / "Contents.json").write_text(
            json.dumps(imageset_contents("grok24.png", "grok48.png"), indent=2) + "\n"
        )
        print(f"installed {dest_dir.name}")


def write_preview(base: Image.Image, path: Path) -> None:
    big, small, pad = 112, 28, 16
    states = [
        ("idle", [0]),
        ("thinking", [0, 10, 20, 30]),
        ("tool", [0, 5, 10, 20]),
        ("compacting", [0, 10, 20, 30]),
        ("done", [0]),
        ("failed", [0]),
        ("needsPermission", [0]),
    ]
    cols = max(len(fr) for _, fr in states) + 1
    W = pad + cols * (big + pad)
    H = pad + len(states) * (big + pad + 18)
    sheet = Image.new("RGBA", (W, H), (0x16, 0x14, 0x11, 255))
    for row, (state, frames) in enumerate(states):
        y = pad + row * (big + pad + 18)
        for col, f in enumerate(frames):
            x = pad + col * (big + pad)
            fr = render_frame(base, state, f).resize((big, big), Image.LANCZOS)
            sheet.alpha_composite(fr, (x, y))
        # 28pt chip
        x = pad + (cols - 1) * (big + pad)
        d = Image.new("RGBA", (big, big), (0x21, 0x1F, 0x1C, 255))
        fr = render_frame(base, state, frames[0]).resize((small, small), Image.LANCZOS)
        d.alpha_composite(fr, ((big - small) // 2, (big - small) // 2))
        sheet.alpha_composite(d, (x, y))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)
    print(f"wrote {path}")


def main() -> None:
    src_path = SRC_DEFAULT
    for arg in sys.argv[1:]:
        if arg.startswith("--src="):
            src_path = Path(arg.split("=", 1)[1])

    raw = load_source(src_path)
    mark = extract_mark(raw)
    base = fit_on_canvas(mark, SIZE, margin=0.14)

    # Keep a high-res extracted mark for the imageset.
    mark_hi = fit_on_canvas(mark, 256, margin=0.10)

    if "--preview" in sys.argv:
        write_preview(base, Path("/tmp/grok-icons-preview.png"))
        return

    OUT.mkdir(parents=True, exist_ok=True)

    # Static states.
    for state, name in (
        ("idle", "grok-idle.png"),
        ("done", "grok-done.png"),
        ("failed", "grok-failed.png"),
        ("needsPermission", "grok-needs-permission.png"),
    ):
        write_static(render_frame(base, state, 0), OUT / name)

    # Animated states.
    for state, name in (
        ("thinking", "grok-thinking.png"),
        ("tool", "grok-tool-call.png"),
        ("compacting", "grok-compressing.png"),
    ):
        frames = [render_frame(base, state, f) for f in range(LOOP)]
        write_apng(frames, OUT / name)

    # Static mark at 24 / 48 for GrokMark.imageset.
    write_static(mark_hi.resize((24, 24), Image.LANCZOS), OUT / "grok-mark-24.png")
    write_static(mark_hi.resize((48, 48), Image.LANCZOS), OUT / "grok-mark-48.png")
    # Also ship a 128 idle copy as design reference.
    write_static(base, OUT / "grok-mark-128.png")

    if "--install" in sys.argv:
        install_into_assets(OUT)


if __name__ == "__main__":
    main()
