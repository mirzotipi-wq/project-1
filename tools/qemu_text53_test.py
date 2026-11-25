#!/usr/bin/env python3
"""Phase 53 font-engine evidence harness.

Boots the real aarch64 kernel under QEMU, renders the embedded TrueType text
card on the mapped framebuffer, and requires in-guest layout, kerning, subpixel,
cache, size and pixel-readback assertions to PASS. The harness independently
checks a QEMU screendump at exact card/header/panel pixels and counts bright
text pixels in the title and price regions. It then arms the test-only glyph
fault: glyph A is skipped, the card must FAIL, and the title ink must visibly
drop in a second screendump before the fault is cleared and the card passes
again.

    zig build
    python3 tools/qemu_text53_test.py

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
CARD = (180, 50, 920, 700)
TITLE = (284, 80, 400, 60)
PRICE = (228, 240, 520, 90)
OUTSIDE = (10, 14, 20)
HEADER = (36, 120, 220)
PANEL = (20, 28, 40)


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


def bright_count(image, box, threshold: int = 190) -> int:
    crop = image.crop((box[0], box[1], box[0] + box[2], box[1] + box[3]))
    crop.load()
    count = 0
    for yy in range(crop.size[1]):
        for xx in range(crop.size[0]):
            r, g, b = crop.getpixel((xx, yy))
            if r > threshold and g > threshold and b > threshold:
                count += 1
    return count


def parse_evidence(output: str) -> int:
    check("text font    : PASS 100 glyphs, upem 2048, kern 220 pairs, 9548 B embedded" in output,
          "embedded face metadata did not match:\n" + output[-4000:])
    layout = re.search(r"text layout  : PASS (\d+) glyphs drawn, missing 0", output)
    check(layout is not None, "layout did not draw every supported glyph:\n" + output[-4000:])
    kern = re.search(r"text kerning : PASS AV (-?\d+) q16 vs A\+V (-?\d+) q16, delta (-?\d+) q16", output)
    check(kern is not None, "kerning line is missing or malformed:\n" + output[-4000:])
    av, separate, delta = (int(kern.group(i)) for i in (1, 2, 3))
    check(delta < 0 and av < separate, f"kerning did not narrow AV: {kern.group(0)}")
    check("text subpixel: PASS 0.0 vs 0.5 px snapshots differ, glyphs 2" in output,
          "subpixel positioning did not change coverage:\n" + output[-4000:])
    cache = re.search(r"text cache   : PASS hits (\d+), misses (\d+), evictions (\d+), entries 64", output)
    check(cache is not None, "glyph cache did not report hits and misses:\n" + output[-4000:])
    check(int(cache.group(1)) > 0 and int(cache.group(2)) > 0, "glyph cache had no hit/miss activity")
    sizes = re.search(r"text sizes   : PASS 8,12,18,24,36,48 px, (\d+) glyphs, (\d+) ink pixels", output)
    check(sizes is not None, "8..48 px size proof did not pass:\n" + output[-4000:])
    check(int(sizes.group(2)) > 1000, f"only {sizes.group(2)} ink pixels reported")
    card = re.search(r"text card    : PASS 920x700 at 180,50, snapshot 0x([0-9a-f]{8})", output)
    check(card is not None, "text card readback did not pass:\n" + output[-4000:])
    check("text verdict : PASS" in output, "text verdict is not PASS:\n" + output[-4000:])
    check("text verdict : FAIL" not in output, "text output contains a FAIL verdict:\n" + output[-4000:])
    return int(card.group(1), 16)


def check_card(image, *, expect_ink: bool = True) -> tuple[int, int]:
    check(image.size == (1280, 800), f"screendump is {image.size}, expected 1280x800")
    x, y, w, h = CARD
    check(image.getpixel((5, 5)) == OUTSIDE, "frame background changed outside the card")
    check(image.getpixel((x + w - 20, y + 50)) == HEADER, "header accent pixel is wrong")
    check(image.getpixel((x + w - 20, y + h - 100)) == PANEL, "panel pixel is wrong")
    title_ink = bright_count(image, TITLE)
    price_ink = bright_count(image, PRICE)
    if expect_ink:
        check(title_ink > 150, f"title region has only {title_ink} bright pixels")
        check(price_ink > 150, f"price region has only {price_ink} bright pixels")
    return title_ink, price_ink


def main() -> int:
    machine = Machine("text53", None, disk=False)
    try:
        info = machine.cmd("text info", 20.0)
        check("TrueType glyf, cmap4, hmtx, legacy kern, 4x AA scanline" in info,
              "text info did not describe the font parser:\n" + info[-2000:])
        check("4-phase subpixel, RTL order, shaping hook" in info,
              "text info did not describe layout features:\n" + info[-2000:])

        good = machine.cmd("text test", 60.0)
        log(good.strip())
        snapshot = parse_evidence(good)
        good_ppm = machine.dir / "text53-good.ppm"
        machine.qmp.screendump(good_ppm)
        image = load_rgb(good_ppm)
        title_ink, price_ink = check_card(image)
        check(title_ink > 150 and price_ink > 150, "screendump did not contain the title and price ink")

        inject = machine.cmd("text inject", 20.0)
        check("text inject  : armed" in inject, "the glyph fault did not arm:\n" + inject[-2000:])
        bad = machine.cmd("text test", 60.0)
        log(bad.strip())
        check("text card    : FAIL" in bad, "corrupted text card still passed:\n" + bad[-4000:])
        check("text verdict : FAIL" in bad, "corrupted text card still claimed PASS:\n" + bad[-4000:])
        check("corrupted=true" in bad, "the glyph fault was not reported:\n" + bad[-4000:])
        bad_ppm = machine.dir / "text53-injected.ppm"
        machine.qmp.screendump(bad_ppm)
        bad_image = load_rgb(bad_ppm)
        bad_title, bad_price = check_card(bad_image, expect_ink=False)
        check(title_ink - bad_title > 60,
              f"skipping glyph A did not visibly reduce title ink: {title_ink} -> {bad_title}")
        check(bad_price >= price_ink - 20,
              "the A-only fault unexpectedly changed the price region")
        check(bad_image.getpixel((5, 5)) == OUTSIDE, "glyph fault changed pixels outside the card")
        diffs = 0
        for yy in range(CARD[1], CARD[1] + CARD[3], 4):
            for xx in range(CARD[0], CARD[0] + CARD[2], 4):
                if image.getpixel((xx, yy)) != bad_image.getpixel((xx, yy)):
                    diffs += 1
        check(diffs > 40, f"glyph fault changed only {diffs} sampled card pixels")

        repair = machine.cmd("text repair", 20.0)
        check("text inject  : cleared" in repair, "the glyph fault did not clear:\n" + repair[-2000:])
        final = machine.cmd("text test", 60.0)
        log(final.strip())
        final_snapshot = parse_evidence(final)
        check(final_snapshot == snapshot, f"repaired snapshot {final_snapshot:#x} != original {snapshot:#x}")
        final_ppm = machine.dir / "text53-final.ppm"
        machine.qmp.screendump(final_ppm)
        final_image = load_rgb(final_ppm)
        final_title, final_price = check_card(final_image)
        check(final_title == title_ink and final_price == price_ink,
              "repaired title/price ink does not match the original")

        try:
            SHOT_DIR.mkdir(parents=True, exist_ok=True)
            final_image.save(SHOT_DIR / "text53-card.png")
        except OSError as exc:
            log(f"[text53] screenshot archive skipped: {exc}")

        log(f"phase 53 font engine: PASS card=180,50 920x700 snapshot=0x{snapshot:08x} "
            f"title_ink={title_ink} price_ink={price_ink} bad_title_ink={bad_title}")
        log("negative control: PASS (glyph A fault rejected and visibly missing, then repaired)")
        return 0
    finally:
        machine.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as exc:
        print(f"FAIL: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
