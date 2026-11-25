# CassaOS graphics core (phase 51)

Phase 51 adds the pixel model below the future rasterizer and compositor. It is
`src/lib/gfx.zig`, a pure, allocation-free Zig module with no MMIO dependency:
surfaces own a bounded byte slice, every operation clips before writing, blits
convert between formats, alpha compositing is straight 8-bit alpha, and a
bounded damage set records the pixels actually touched. The kernel-facing proof
is `src/kernel/gfx51.zig`; it wraps the real mapped framebuffer in a surface and
reads the pixels back after drawing.

The phase done criterion is **host snapshot tests pass for all formats and
clipping cases**. That is proved by `zig build test --summary all`. In addition,
the booted QEMU harness proves the same code against the actual framebuffer and
checks the display pixels independently.

## Format contract

| Format | Bytes/pixel | Memory order | Alpha on read | Alpha on write |
|---|---:|---|---|---|
| `bgrx8888` | 4 | B, G, R, unused | 255 | ignored |
| `rgba8888` | 4 | R, G, B, A | stored A | preserved by `setPixel` |
| `rgb888` | 3 | R, G, B | 255 | ignored |
| `rgb565` | 2 | little-endian R5G6B5 | 255 | ignored |

`bgrx8888` matches the QEMU bochs-display path already used by phase 37.
`rgba8888` is the image/source format that carries per-pixel alpha;
`rgb888`/`rgb565` cover lower-depth panels. `Color` is `0xAARRGGBB`.

`Surface.init(pixels, width, height, stride, format)` rejects zero geometry,
a stride smaller than `width * bytes_per_pixel`, and a buffer shorter than
`stride * height`. It retains the exact visible-pixel slice only; row padding is
never touched by drawing. `snapshot()` hashes visible pixels without stride
padding.

## Drawing semantics

- `clip(rect)` intersects the requested rectangle with both the surface bounds
  and the current clip rectangle. Negative origins, zero/negative sizes,
  right/bottom overflow and a fully outside rectangle all produce `null`.
- `fillRect(x, y, w, h, color)` is `O(visible pixels)`. An opaque fill writes
  raw rows; a translucent fill reads, blends and writes each pixel.
- `blit(dst, src, src_rect, dst_rect, opacity)` copies 1:1 (no scaling). It clips
  the source first, translates the visible source rectangle into destination
  coordinates, clips again, and composites source `A * opacity / 255` over the
  destination. Only the final visible rectangle is added to damage.
- `setPixel` writes raw RGBA alpha; it is for authoring source images, not for
  compositing. `fillRect` is the compositing destination operation.
- `Damage` holds at most **8** rectangles. Overlapping or touching rectangles
  coalesce into their bounding union; when full, the last entry absorbs the new
  region rather than allocating or silently dropping it. `pixels()` sums the
  stored rectangles (already unioned), and `bounds()` returns the overall hull.

The blend is integer straight alpha:

```
a = (src_alpha * opacity + 127) / 255
out = (src * a + dst * (255 - a) + 127) / 255
```

A zero-alpha source leaves the destination byte-for-byte unchanged; a full-alpha
source replaces its RGB channels. This matters for transparent source images and
is covered by a regression test.

## Host snapshot and behaviour tests

The module is imported by `src/tests.zig`. The phase-51 tests are:

- `all formats round-trip alpha and RGB`
- `clipping covers negative, overflow, empty and boundary rectangles`
- `clipping is exact in every pixel format`
- `blit converts between every source and destination format` (all 4 × 4 pairs)
- `translucent fill and blit composite exact channels`
- `blit clips source and destination and records only visible damage`
- `damage coalesces, clips and is bounded`
- `format snapshots are stable`

The stable snapshots are CRC32C over the visible bytes of an identical rendered
scene:

| Format | Snapshot |
|---|---|
| `bgrx8888` | `0x7d245e17` |
| `rgba8888` | `0x0c78f0ce` |
| `rgb888` | `0x4d34cea1` |
| `rgb565` | `0xc7e3a61c` |

Observed host result on the phase-51 tree:

```
Build Summary: 3/3 steps succeeded; 264/264 tests passed
```

That is the phase-50 count of 256 plus eight phase-51 tests.

## Booted proof

`python3 tools/qemu_gfx51_test.py` boots the real aarch64 image with the
1280x800 bochs-display, no disk, and runs `gfx info` then `gfx test`. `gfx test`
first checks all four format round-trips and a scratch clip/blit/blend/damage
scenario, then draws a deterministic 128×96 card at `576,352` through the
mapped framebuffer:

- clipped red rectangle (`-16,-16` origin, clipped to the card);
- opaque green rectangle;
- translucent blue fill composited over the card background;
- 32×32 RGBA source with white, transparent, half-green and orange quadrants,
  blitted onto the card.

The kernel verifies the exact pixels after drawing, records damage, and prints:

```
  gfx formats : bgrx8888 rgba8888 rgb888 rgb565
  gfx encode  : PASS (all four formats round-trip)
  gfx clip    : PASS (negative and overflow draws clipped to the card)
  gfx blit    : PASS (RGBA source, per-pixel alpha, clipped)
  gfx damage  : PASS (1 rect(s), 12288 px)
  gfx frame   : 1280x800 x8r8g8b8, card 576,352 128x96
  gfx snapshot: 0x27ae8280
  gfx core    : PASS
```

The harness does not accept those lines alone. It also takes a QEMU screendump
and checks these pixels independently:

| Pixel (card-relative) | Expected RGB | Meaning |
|---|---|---|
| `8,8` | `220,32,32` | clipped red |
| `72,8` | `32,180,64` | opaque green |
| `8,56` | `8,44,144` | blue alpha 128 over `16,24,32` |
| `72,56` | `255,255,255` | opaque source quadrant |
| `80,56` | `16,24,32` | transparent source leaves background |
| `72,72` | `8,140,16` | green alpha 128 over background |
| `80,72` | `255,128,0` | opaque orange source |

The screenshot is archived as `docs/screenshots/gfx51-card.png`.

### Negative control

`gfx inject` arms a test-only hook that corrupts the drawn card after the real
operations; `gfx test` must then report `gfx core : FAIL` with a different
snapshot (`0xda4f8ba2` observed), and the harness checks the magenta corruption
in the QEMU framebuffer. `gfx repair` clears the hook and the next test returns
to the exact clean snapshot. This proves the proof is sensitive to a broken or
disabled output, rather than only printing PASS unconditionally.

Observed harness line:

```
phase 51 graphics core: PASS card=576,352 128x96 snapshot=0x27ae8280
negative control: PASS (injected card corruption rejected, then repaired)
```

## Prior harness re-runs

All thirteen prior harnesses were run one at a time against the same built
image. Observed evidence:

| Harness | Observed result |
|---|---|
| input | `4006381333931 (13 chars, 260 ms burst)`; delivery `0 ms`, budget `20 ms`; screenshot/fallback PASS |
| usb | `USB scenarios: 4/4 PASS` |
| power | normal `2390 ms` → critical `3763 ms` (**1.57x**); watchdog, poweroff, brownout, fallback PASS |
| cassafs | phase 41 CASSAFS evidence: PASS (format/verify, host reader, reboot, fallback, corruption, absence) |
| vfs | phase 42 VFS evidence: PASS (mount, stable readdir, remount/reboot, refusals) |
| vfs_write | `7 bytes, CRC32C 0xdb03992b`; `8 bytes, CRC32C 0x394478f0`; out-of-space/corruption PASS |
| page_cache | `sale commit: max 29 ms / 100 ms budget`; `sale file: 33 B, CRC32C 0x12b569fa (asserted)`; `64/64 pages, 344 evictions, 88 writebacks, 20 flushes` |
| fat32 | `10000 rows, 220021 B, max line 21, CRC32C 0x8678e4e7` (three imports); corrupt chain and one-partition refusal PASS |
| vfs46 | `10000 rows, 220021 B, max line 21, CRC32C 0x8678e4e7`; three-backend paths, tmpfs, chmod, locks, watches, remount PASS |
| retail | `239 records, 64 receipts, 128 lines`; `subtotal 42020, units 160, cash 16540, variance 50`; top `100001 Croissant`; corruption refusal PASS |
| sales48 | `3 transaction(s), 6 unit(s), subtotal 1555, tax 0, total 1555 cents`; observed chain CRC `0x9ea23dc9`; retry/conflict/corruption/reboot PASS |
| storage49 | baseline fsck PASS; transient read/flush recovery; persistent failure `REFUSED: Io` then `REFUSED: BadBlock`; scrub cleared 1 bad entry and fsck PASS; `BadCrc` on separate fixture PASS |
| recovery50 | config generation 3 in slot 3; `REFUSED: BadCrc` then one-command rollback; bundle **1312 B / CRC32C `0x66d093ce`**; audit **576 B**; factory reset preserve PASS |

The sale-log chain CRC remains intentionally **boot-uptime dependent**. The
record timestamp at bytes 80..87 is `timer.uptimeMs()` and is inside the record
CRC, so no fixed sale-chain value is asserted. The phase-51 runs observed
`0x9ea23dc9` in sales48 (3 transactions) and `0x61fa4d8c` in recovery50's
one-sale check; both are evidence, not golden constants.

## Limits

- This is a software CPU pixel path. It has no SIMD/NEON fast path, no GPU or
  blitter acceleration, and no scaling, rotation, rounded primitives or
  anti-aliasing; those are phase 52 and later.
- Alpha is straight 8-bit alpha only. There is no premultiplied-alpha mode, no
  color management/gamma-correct blending, and no 10-bit/HDR/indexed/YUV format.
- The four formats are the existing framebuffer depths plus an RGBA source
  format. Pixel format conversion is 1:1 and quantizes into RGB565; it does not
  dither.
- Damage is a bounded 8-rectangle set. Coalescing uses bounding unions, so it
  can mark more pixels than strictly necessary; it is not a minimal dirty-region
  solver and has no per-tile hierarchy.
- The core is allocation-free and caller-owned: a `Surface` does not allocate,
  resize, tile or manage a glyph atlas. The compositor, double buffering, vsync
  and cursor plane are phase 54.
- The direct `fb.zig` panic/splash/test-pattern routines still exist for the
  phase-37 fault-safe path. Phase 51 is the new core used by the `gfx` self-test
  and the intended layer for phases 52–55; not every existing UI draw has been
  migrated to it yet.
- The booted pixel check is one 1280x800 BGRX QEMU panel with the bochs-display
  device. Other panel strides/formats are covered by host tests, not by physical
  hardware.
- Test-only `gfx inject` is a verification control, not a production feature.
