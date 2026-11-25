#!/usr/bin/env python3
"""Phase 52 rasterizer evidence harness.

Boots the real aarch64 kernel under QEMU, draws the 320x240 proof card through
the phase-52 rasterizer, and requires in-guest pixel readback to PASS. The
harness independently inspects a QEMU screendump at every feature, checks the
timed 1920x1080 / 500-primitive benchmark, and then arms the test-only
corruption hook: the same card must fail and the corrupted pixel must be
visible in a second screendump before the hook is cleared and the card passes
again.

Build the performance image first (the 8 ms target is a release-build claim):

    zig build -Drelease=true
    python3 tools/qemu_raster52_test.py

QEMU=/path/to/qemu-system-aarch64 may override the binary.
"""

from __future__ import annotations

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from qemu_vfs_test import Failure, Machine, check, log  # noqa: E402

SHOT_DIR = Path(__file__).resolve().parent.parent / "docs" / "screenshots"

# (name, card-relative x, y, expected RGB from the real bgrx8888 panel)
CARD_PIXELS = (
    ("gradient-top", 1, 1, (16, 24, 32)),
    ("gradient-row8", 8, 8, (17, 25, 33)),
    ("accent", 160, 36, (36, 120, 220)),
    ("circle", 56, 120, (38, 196, 108)),
    ("arc", 28, 148, (255, 150, 40)),
    ("line", 120, 92, (240, 244, 248)),
    ("patch-centre", 200, 156, (44, 104, 236)),
    ("patch-corner", 121, 125, (212, 52, 52)),
    ("patch-edge", 200, 125, (52, 188, 92)),
)

OUTSIDE_PIXELS = (
    ("outside-left", -1, 1),
    ("outside-right", 320, 1),
)


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


def parse_evidence(output: str) -> tuple[int, int]:
    check("raster API    : rounded-rect circle line arc gradient shadow nine-patch" in output,
          "the rasterizer did not report its full primitive set:\n" + output[-3000:])
    card = re.search(r"raster card\s+:\s+PASS 320x240 at (\d+),(\d+), snapshot 0x[0-9a-f]{8}", output)
    check(card is not None, "card readback did not pass:\n" + output[-3000:])
    check("raster damage : PASS (1 rect(s), 76800 px)" in output,
          "damage was not exactly the visible card:\n" + output[-3000:])
    bench = re.search(
        r"raster bench\s+:\s+PASS 1920x1080 rgb565, 500 primitives, "
        r"min (\d+) us median (\d+) us max (\d+) us", output)
    check(bench is not None, "1080p/500-primitive benchmark did not pass:\n" + output[-3000:])
    low, median, high = (int(bench.group(i)) for i in (1, 2, 3))
    check(low <= median <= high, f"benchmark samples are not ordered: {bench.group(0)}")
    check(median < 8000, f"median 1080p/500-primitive time is {median} us, expected <8000 us")
    check("raster frames : PASS 2500/2500 primitive centres, five timed frames" in output,
          "per-primitive frame readback did not pass:\n" + output[-3000:])
    check("raster heap   : PASS allocated 4147200 B, used 0->0 B, largest free 8388584->8388584 B" in output,
          "1080p RGB565 allocation was not exactly reclaimed:\n" + output[-3000:])
    check("raster verdict: PASS" in output, "raster verdict is not PASS:\n" + output[-3000:])
    return int(card.group(1)), int(card.group(2))


def check_card(image, card_x: int, card_y: int, corrupted: bool = False) -> None:
    for name, dx, dy, expected in CARD_PIXELS:
        if corrupted and name == "circle":
            expected = (255, 0, 255)
        actual = image.getpixel((card_x + dx, card_y + dy))
        check(actual == expected,
              f"{name} pixel at {card_x + dx},{card_y + dy} is {actual}, expected {expected}")
    if corrupted:
        actual = image.getpixel((card_x + 56, card_y + 120))
        check(actual == (255, 0, 255),
              f"injected corruption was not visible in the framebuffer: {actual}")


def main() -> int:
    machine = Machine("raster52", None, disk=False)
    try:
        info = machine.cmd("raster info", 20.0)
        check("raster API    : rounded-rect circle line arc gradient shadow nine-patch" in info,
              "raster info did not describe the primitive set:\n" + info[-2000:])
        check("4xu32/8xu16 vector fills" in info and "fixed-point" in info,
              "raster info did not describe the vector/fixed-point implementation:\n" + info[-2000:])

        good = machine.cmd("raster test", 25.0)
        log(good.strip())
        card_x, card_y = parse_evidence(good)

        good_ppm = machine.dir / "raster52-good.ppm"
        machine.qmp.screendump(good_ppm)
        image = load_rgb(good_ppm)
        check(image.size == (1280, 800), f"screendump is {image.size}, expected 1280x800")
        check_card(image, card_x, card_y)
        outside = image.getpixel((card_x - 1, card_y + 1))
        for name, dx, dy in OUTSIDE_PIXELS:
            actual = image.getpixel((card_x + dx, card_y + dy))
            check(actual == outside, f"{name} changed from the frame background: {actual} != {outside}")

        inject = machine.cmd("raster inject", 20.0)
        check("raster inject : armed" in inject, "the corruption hook did not arm:\n" + inject[-2000:])
        bad = machine.cmd("raster test", 25.0)
        log(bad.strip())
        check("raster card   : FAIL" in bad, "readback did not reject the corrupted card:\n" + bad[-3000:])
        check("circle=0xffff00ff" in bad, "corrupted circle pixel was not identified:\n" + bad[-3000:])
        check("raster verdict: FAIL" in bad, "corrupted card still claimed PASS:\n" + bad[-3000:])
        check("raster verdict: PASS" not in bad, "corrupted card still printed a PASS verdict:\n" + bad[-3000:])

        bad_ppm = machine.dir / "raster52-injected.ppm"
        machine.qmp.screendump(bad_ppm)
        check_card(load_rgb(bad_ppm), card_x, card_y, corrupted=True)

        repair = machine.cmd("raster repair", 20.0)
        check("raster inject : cleared" in repair, "the corruption hook did not clear:\n" + repair[-2000:])
        final = machine.cmd("raster test", 25.0)
        log(final.strip())
        parse_evidence(final)
        final_ppm = machine.dir / "raster52-final.ppm"
        machine.qmp.screendump(final_ppm)
        check_card(load_rgb(final_ppm), card_x, card_y)

        try:
            SHOT_DIR.mkdir(parents=True, exist_ok=True)
            load_rgb(final_ppm).save(SHOT_DIR / "raster52-card.png")
        except OSError as exc:
            log(f"[raster52] screenshot archive skipped: {exc}")

        bench = re.search(r"raster bench\s+:\s+PASS .*", final)
        log(f"phase 52 rasterizer: PASS card={card_x},{card_y} 320x240")
        log(bench.group(0) if bench else "benchmark line missing")
        log("negative control: PASS (injected pixel rejected and visible, then repaired)")
        return 0
    finally:
        machine.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as exc:
        print(f"FAIL: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
