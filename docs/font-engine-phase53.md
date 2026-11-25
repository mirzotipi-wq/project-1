# Phase 53 — Font engine

**Goal:** legible prices at arm's length, with real TrueType outlines instead of the
phase-37 5x7 console face.

## What was built

`src/lib/font.zig` is a pure Zig, allocation-free font engine on top of the phase-51
`gfx.Surface` and the phase-52 colour/raster primitives:

- **Embedded face.** `src/lib/font_data.zig` contains a 9,548-byte DejaVu Sans subset:
  100 glyphs, 2,048 units/em, printable ASCII 0x20–0x7E plus `€`, `£`, `¥` and `°`, and
  220 legacy `kern` pairs. It is ordinary Zig byte data, not a runtime file. The subset was
  generated once with fontTools from the project's host font and checked into the tree; the
  kernel needs no filesystem or font service to draw text. The source face is DejaVu Sans
  (Bitstream Vera license); the subset is embedded data, not linked foreign code.
- **TrueType parser.** Table-directory bounds checks and reads for `head`, `maxp`, `hhea`,
  `hmtx`, `cmap` format 4, short/long `loca`, simple `glyf` and the first horizontal
  format-0 `kern` subtable. All reads are bounded; malformed lengths return `BadFont` or
  `BadGlyph`. Composite glyphs are rejected explicitly, not guessed at.
- **Quadratic flattening.** Contours are transformed to Q16 pixels, off-curve runs get their
  implied midpoints, and quadratic segments are subdivided adaptively until the control point
  is within 1/16 px of the chord (maximum depth 6). This keeps small text smooth and large
  text accurate without a fixed segment count.
- **Anti-aliased scanline coverage.** Every glyph row gets four vertical sub-scanlines. Segment
  crossings are sorted, filled with the nonzero winding rule, and horizontal overlap is
  accumulated exactly in Q16 into a `u16` coverage cell. The result is clamped to `u8`; there
  is no floating point, libc or second graphics path. The bitmap rectangle is clipped and
  bounds-checked to 64×64 pixels.
- **Layout.** `font.measure` and `font.drawText` share the same UTF-8 decoder, optional
  codepoint shaping hook, direction ordering, kern lookup and hmtx advance path. The pen is
  Q16; `AV` at 48 px measures 4,102,656 q16 against 4,303,872 q16 for A+V, a **−201,216 q16
  (3.07 px)** kern. Four subpixel phases (0, ¼, ½, ¾ px) are part of the cache key and shift
  the outline before rasterization.
- **Bounded atlas.** A `Renderer` owns 64 coverage cells of 64×64 bytes and an LRU clock.
  Hits refresh the entry; misses rasterize into the least-recently-used or first free cell.
  The kernel keeps one `Renderer` in `.bss`; there is no per-frame allocation.
- **Fallback.** Unsupported codepoints, composite glyphs and rasterizer refusals draw the
  phase-37 5x7 glyph (or `?` for a non-ASCII missing codepoint) with the same advance, so text
  never silently disappears. The fallback is deliberately not anti-aliased.
- **RTL and hooks.** `DrawOptions.direction = .rtl` reverses the prepared run; a
  `shape_hook: ?*const fn (u21) u21` can map codepoints before layout. This is a hook and a
  run reversal, not a Unicode bidi algorithm, Arabic joining or ligature engine.

The shell command is `text [test|inject|repair|info]`; the live proof is
`src/kernel/text53.zig`.

## Live QEMU evidence

`python3 tools/qemu_text53_test.py` boots the real aarch64 image with no disk. The card is
920×700 at `180,50` on the 1280×800 panel. Captured final run:

```
text font    : PASS 100 glyphs, upem 2048, kern 220 pairs, 9548 B embedded
text layout  : PASS 254 glyphs drawn, missing 0, all printable ASCII at 10 px
text kerning : PASS AV 4102656 q16 vs A+V 4303872 q16, delta -201216 q16
text subpixel: PASS 0.0 vs 0.5 px snapshots differ, glyphs 2
text cache   : PASS hits 76, misses 692, evictions 628, entries 64
text sizes   : PASS 8,12,18,24,36,48 px, 256 glyphs, 19152 ink pixels
text card    : PASS 920x700 at 180,50, snapshot 0x809a41f2
text verdict : PASS
```

`text layout` draws all 95 printable ASCII codepoints individually at 10 px and requires
`missing 0`; the card also contains the title, price, card line, subtotal, six size samples
and LTR/RTL/subpixel samples. The in-guest verdict requires the font metadata, layout,
kerning, subpixel, cache and size checks to all pass.

The harness independently loads the QEMU screendump and checks:

- the 1280×800 size and the exact frame background `(10,14,20)` outside the card;
- the header accent `(36,120,220)` and panel `(20,28,40)` at pixels away from text;
- **977** bright title pixels and **1,518** bright price pixels in the good card;
- the repaired card has the same in-guest snapshot and the same title/price ink counts.

### Negative path

`text inject` arms a test-only fault: the next render skips glyph `A` and marks the result
`corrupted`. The same proof must then print `text card : FAIL` and `text verdict : FAIL`.
The harness independently observes the title region drop from **977 to 618** bright pixels,
checks the price region is essentially unchanged (the fault is A-only), samples more than 40
changed card pixels, and confirms nothing outside the card changed. `text repair` clears the
fault; the final card returns to snapshot `0x809a41f2` and PASS.

This is a font-path failure, not a painted magenta marker: the glyph is actually omitted from
the layout and the in-guest checks reject it. The screenshot archive is
`docs/screenshots/text53-card.png`.

## Prior harnesses on the phase-53 tree

All fifteen certified harnesses listed for this increment were run one at a time on the exact
tree, not in parallel:

| Harness | Captured evidence |
|---|---|
| input | `4006381333931`, 13 chars, 257 ms burst, 1 ms delivery |
| usb | 4/4 scenarios |
| power | normal 2554 ms → critical 3825 ms (1.50x), clear restored 42.000 C |
| cassafs / vfs / vfs_write | PASS (format, read, write, screenshots) |
| page_cache | max 37 ms/100 ms; 64/64 pages, 344 evictions, 88 writebacks, 20 flushes; sale 33 B `0x12b569fa` |
| fat32 | 10,000 rows / 220,021 B / max line 21 / `0x8678e4e7` |
| vfs46 | same import; three backends, tmpfs, chmod, locks and watches PASS |
| retail | 239 records / 64 receipts / 128 lines; subtotal 42,020 / 160 units |
| sales48 | 3 transactions / 6 units / 1,555 cents; chain `0x603c820f` is boot-dependent and not asserted |
| storage49 | PASS (transient recovery, persistent refusal, scrub/fsck, raw `BadCrc`) |
| recovery50 | bundle 1312 B / `0x66d093ce`; audit 576 B; chain `0xf5a230a2` boot-dependent |
| gfx51 | PASS, snapshot `0x27ae8280`, injected corruption rejected and repaired |
| raster52 | release PASS; 1920×1080 RGB565 500 primitives, 4,429/4,883/5,321 µs |

## Host tests

`src/tests.zig` imports `lib/font.zig`. The suite grows from phase 52's **272** to **282**
tests (+10):

- table parse, units/num glyphs, kern presence and advance;
- all printable ASCII plus `€ £ ¥ °` map to glyphs;
- simple outline contours/points and bounds;
- 8/12/24/48 px coverage is non-empty and within 64×64;
- `AV` kerning narrows the measured width and cache reuse produces hits;
- four-phase subpixel coverage differs;
- RTL and shaping-hook layout paths;
- unsupported `U+4E2D` uses a visible fallback;
- all six required sizes draw ink;
- the last glyph (euro, gid 99) rasterizes, which caught and fixed the `loca` end-index
  boundary.

## Honest limits

- The face is a **100-glyph Latin subset**, not a full Unicode font. Coverage is printable
  ASCII plus four price symbols; anything else uses the 5x7 fallback.
- Kerning comes from the legacy `kern` table (220 pairs). GPOS kerning, ligatures, Arabic
  joining, Indic shaping and a full bidi algorithm are **not** implemented. `rtl` is run
  reversal plus a codepoint hook.
- Subpixel positioning has **four phases**, not a full 1/64 pen grid.
- Composite glyphs are rejected and fall back; accented Latin text is outside this increment.
- The fallback is a scaled bitmap, not anti-aliased; it is a safety path, not a typographic
  face.
- QEMU TCG is not native Cortex-A53 hardware. The card's raw framebuffer snapshot is
  diagnostic; the harness asserts deterministic card pixels and the screendump, not a
  boot-specific raw CRC. The snapshot did repeat exactly across the good, injected and
  repaired/recovered runs in this increment.
- The 64-entry cache produced 628 evictions during the six-size/95-glyph proof. This is
  bounded and intentional; a packed production atlas would reduce churn but is not claimed.
- No font hinting is used; the adaptive curve flattening and four vertical subsamples are the
  quality mechanism demonstrated here.

## Files

- `src/lib/font.zig` — parser, rasterizer, layout, atlas, tests.
- `src/lib/font_data.zig` — embedded 9,548-byte subset.
- `src/kernel/text53.zig` — live card, size/ASCII proof, test-only fault, command.
- `src/kernel/shell.zig` — `text` import, dispatch and help.
- `src/tests.zig` — host-test import.
- `tools/qemu_text53_test.py` — QEMU harness and screendump checks.
- `docs/screenshots/text53-card.png` — captured card.
