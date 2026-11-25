#!/usr/bin/env python3
"""Phase 51 graphics-core evidence harness.

Boots the real aarch64 kernel under QEMU and asks the shell to draw a
deterministic 128x96 card through the phase-51 graphics core. PASS comes from
the kernel's pixel readback, and the harness independently checks the QEMU
screendump at known card coordinates. It then arms the test-only corruption
hook and requires the same self-check to fail, proving the proof is sensitive to
a broken output rather than only trusting a printed line.

Usage:  python3 tools/qemu_gfx51_test.py
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_gfx51_test.py
"""

from __future__ import annotations

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from qemu_vfs_test import Failure, Machine, check, log  # noqa: E402

SHOT_DIR = Path(__file__).resolve().parent.parent / "docs" / "screenshots"
EXPECTED_SNAPSHOT = "0x27ae8280"

# (name, card-relative x, y, expected RGB from the real bgrx8888 panel)
CARD_PIXELS = (
    ("red", 8, 8, (220, 32, 32)),
    ("green", 72, 8, (32, 180, 64)),
    ("alpha-blue", 8, 56, (8, 44, 144)),
    ("source-white", 72, 56, (255, 255, 255)),
    ("source-transparent", 80, 56, (16, 24, 32)),
    ("source-green-alpha", 72, 72, (8, 140, 16)),
    ("source-orange", 80, 72, (255, 128, 0)),
)


def parse_evidence(output: str) -> tuple[int, int, int, int]:
    check("gfx formats : bgrx8888 rgba8888 rgb888 rgb565" in output,
          "phase-51 formats were not reported:\n" + output[-3000:])
    check("gfx encode  : PASS (all four formats round-trip)" in output,
          "format round-trip proof did not pass:\n" + output[-3000:])
    check("gfx clip    : PASS (negative and overflow draws clipped to the card)" in output,
          "clip proof did not pass:\n" + output[-3000:])
    check("gfx blit    : PASS (RGBA source, per-pixel alpha, clipped)" in output,
          "blit/alpha proof did not pass:\n" + output[-3000:])
    check("gfx damage  : PASS (1 rect(s), 12288 px)" in output,
          "damage proof did not pass:\n" + output[-3000:])
    frame = re.search(r"gfx frame\s+:\s+(\d+)x(\d+) (\S+), card (\d+),(\d+) (\d+)x(\d+)", output)
    check(frame is not None, "framebuffer/card geometry missing:\n" + output[-3000:])
    check(frame.group(1) == "1280" and frame.group(2) == "800",
          f"unexpected QEMU panel geometry: {frame.group(0)}")
    check(frame.group(3) == "x8r8g8b8", f"unexpected QEMU panel format: {frame.group(0)}")
    check(frame.group(6) == "128" and frame.group(7) == "96", f"unexpected card size: {frame.group(0)}")
    snapshot = re.search(r"gfx snapshot:\s+(0x[0-9a-f]{8})", output)
    check(snapshot is not None, "card snapshot missing:\n" + output[-3000:])
    check(snapshot.group(1) == EXPECTED_SNAPSHOT,
          f"card snapshot changed: {snapshot.group(1)}, expected {EXPECTED_SNAPSHOT}")
    check("gfx core    : PASS" in output, "graphics-core verdict is not PASS:\n" + output[-3000:])
    return (int(frame.group(4)), int(frame.group(5)), int(frame.group(6)), int(frame.group(7)))


def load_rgb(ppm: Path):
    try:
        from PIL import Image
    except ImportError as exc:
        raise Failure(f"Pillow is required to inspect the screendump: {exc}")
    deadline = time.time() + 5.0
    while not ppm.exists() and time.time() < deadline:
        time.sleep(0.05)
    check(ppm.exists(), f"screendump did not produce {ppm}")
    with Image.open(ppm) as image:
        return image.convert("RGB")


def check_card_pixels(image, card_x: int, card_y: int, injected: bool = False) -> None:
    for name, dx, dy, expected in CARD_PIXELS:
        if injected and name == "red":
            expected = (255, 0, 255)
        actual = image.getpixel((card_x + dx, card_y + dy))
        check(actual == expected, f"{name} pixel at {card_x + dx},{card_y + dy} is {actual}, expected {expected}")
    if injected:
        actual = image.getpixel((card_x + 8, card_y + 8))
        check(actual == (255, 0, 255), f"injected corruption was not visible in the framebuffer: {actual}")
    else:
        actual = image.getpixel((card_x + 1, card_y + 1))
        check(actual == (220, 32, 32), f"clean card top-left is {actual}, expected red")


def main() -> int:
    machine = Machine("gfx51", None, disk=False)
    try:
        info = machine.cmd("gfx info", 20.0)
        check("gfx formats : bgrx8888 rgba8888 rgb888 rgb565" in info,
              "gfx info did not describe all formats:\n" + info[-2000:])
        check("straight alpha" in info and "bounded damage" in info,
              "gfx info did not describe the compositing/damage capabilities:\n" + info[-2000:])

        good = machine.cmd("gfx test", 25.0)
        log(good.strip())
        card_x, card_y, card_w, card_h = parse_evidence(good)
        check(card_w == 128 and card_h == 96, "card geometry was not 128x96")

        good_ppm = machine.dir / "gfx51-good.ppm"
        machine.qmp.screendump(good_ppm)
        good_image = load_rgb(good_ppm)
        check(good_image.size == (1280, 800), f"screendump is {good_image.size}, expected 1280x800")
        check_card_pixels(good_image, card_x, card_y)

        inject = machine.cmd("gfx inject", 20.0)
        check("gfx inject  : armed" in inject, "the corruption hook did not arm:\n" + inject[-2000:])
        bad = machine.cmd("gfx test", 25.0)
        log(bad.strip())
        check("gfx clip    : FAIL" in bad, "readback did not reject the corrupted card:\n" + bad[-3000:])
        check("gfx core    : FAIL" in bad, "corrupted card was not rejected:\n" + bad[-3000:])
        check("gfx core    : PASS" not in bad, "corrupted card still claimed PASS:\n" + bad[-3000:])
        bad_snapshot = re.search(r"gfx snapshot:\s+(0x[0-9a-f]{8})", bad)
        check(bad_snapshot is not None, "negative control produced no snapshot:\n" + bad[-3000:])
        check(bad_snapshot.group(1) != EXPECTED_SNAPSHOT,
              "negative control did not change the card snapshot")

        bad_ppm = machine.dir / "gfx51-injected.ppm"
        machine.qmp.screendump(bad_ppm)
        bad_image = load_rgb(bad_ppm)
        check_card_pixels(bad_image, card_x, card_y, injected=True)

        repair = machine.cmd("gfx repair", 20.0)
        check("gfx inject  : cleared" in repair, "the corruption hook did not clear:\n" + repair[-2000:])
        final = machine.cmd("gfx test", 25.0)
        log(final.strip())
        parse_evidence(final)
        final_ppm = machine.dir / "gfx51-final.ppm"
        machine.qmp.screendump(final_ppm)
        check_card_pixels(load_rgb(final_ppm), card_x, card_y)

        try:
            SHOT_DIR.mkdir(parents=True, exist_ok=True)
            load_rgb(final_ppm).save(SHOT_DIR / "gfx51-card.png")
        except OSError as exc:
            log(f"[gfx51] screenshot archive skipped: {exc}")

        log(f"phase 51 graphics core: PASS card={card_x},{card_y} {card_w}x{card_h} snapshot={EXPECTED_SNAPSHOT}")
        log("negative control: PASS (injected card corruption rejected, then repaired)")
        return 0
    finally:
        machine.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as exc:
        print(f"FAIL: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
