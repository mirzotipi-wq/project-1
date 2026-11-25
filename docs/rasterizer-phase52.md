# CassaOS 2D rasterizer (phase 52)

Phase 52 adds the drawing layer above the phase-51 pixel core. It is split in
two, with no second graphics path:

- `src/lib/gfx.zig` remains the owner of pixel formats, clipping, alpha
  compositing and damage. Phase 52 adds the public `fillSpan` fast path and the
  public `blendPixel` entry; `fillRect`, the rasterizer and `blit` all composite
  through those same checked functions.
- `src/lib/raster2d.zig` is a pure, allocation-free Zig module for filled and
  rounded rectangles, circles, anti-aliased lines and arcs, linear gradients,
  layered shadows and nine-patch scaling.
- `src/kernel/raster52.zig` is the live proof and the `raster` shell command. It
  draws on the real mapped framebuffer and times an off-screen RGB565 frame.

All arithmetic is integer or fixed point. The kernel uses no floating point in
this path, no libc, no C import and no assembly.

## Layer contract

`Surface.fillSpan(x, y, len, color)` clips the span to the surface and current
clip rectangle, then writes an opaque row. The 32-bit formats store four pixels
per `@Vector(4, u32)` operation and RGB565 stores eight per `@Vector(8, u16)`;
RGB888 keeps a scalar tail because three bytes are not a natural vector width.
A scalar tail handles lengths that are not a multiple of the vector width.
`Surface.blendPixel` is the single per-pixel source-over path. Damage remains the
caller's responsibility.

The rasterizer uses doubled pixel-centre coordinates for edge coverage:

```
dx = 2*x + 1 - 2*centre_x
coverage = 255                     if dx²+dy² <= (r-1)²
         = 0                       if dx²+dy² >= (r+1)²
         = 255 - (d²-inner²)*255 / (outer²-inner²)   otherwise
```

The ramp is a linear approximation to a one-pixel coverage band, not an exact
area integral. It is deterministic and needs no square root. The straight body
of a rounded rectangle is written with vector spans; only its four corner
squares take the per-pixel coverage path. A circle is a rounded rectangle of
equal width and height.

Lines compute the closest point on the segment in integer projection space,
clamp the projection to the endpoints (round caps), and apply the same coverage
function to the distance from the pixel centre. Arcs are chains of these AA
segments sampled from a 65-entry Q14 sine/cosine table at 1/64 turn; angle `0`
points right and angle `16` points down the framebuffer. A 64-step circle has a
chord error below one pixel at the UI radii used here; very large radii or a
demand for exact conic arcs would need adaptive subdivision.

Gradients are two-stop integer RGB(A) lerps. Vertical gradients write one vector
span per row; horizontal gradients composite one pixel per column. There is no
dithering, multi-stop ramp or gamma correction. Shadows are four concentric
rounded layers with increasing alpha, offset down and right; this is a bounded
approximation, not a Gaussian blur. Nine-patch scaling keeps the source corners
at their natural size and stretches the four edges and the centre with
nearest-neighbour sampling. The source and destination must be different
surfaces; there is no bilinear filter.

## Commands and host tests

`raster [test|inject|repair|info]` is registered in the real shell and `help`
lists it. `raster info` describes the API, vector spans, fixed-point math and
benchmark shape. `raster inject` arms a test-only corruption of the verified
circle pixel; `raster repair` clears it. The normal `raster test` verdict is
computed from readback, allocation accounting and measured time, never from a
hardcoded PASS.

`raster2d.zig` and `gfx.zig` are imported by `src/tests.zig`. The phase adds
**8 host tests** (7 rasterizer cases and one span test): rounded corners and
straight bodies, round/clipped circles, AA/clipped lines, a quadrant arc,
gradient endpoints, shadow darkness, nine-patch corners/edges/centre, and exact
vector/tail span bytes in all four formats.

Observed on the phase-52 tree:

```
Build Summary: 3/3 steps succeeded; 272/272 tests passed
```

That is the phase-51 count of 264 plus the eight new tests.

## Booted card proof

The release image was built with `zig build -Drelease=true` and booted by
`tools/qemu_raster52_test.py` with the 1280x800 bochs-display, no disk. `raster
test` draws this card at **480,280, 320x240**:

- vertical gradient from `16,24,32` to `32,56,72`;
- four-layer shadow behind the main rounded panel;
- rounded panel `28,38,52` and a rounded blue accent `36,120,220`;
- green circle `38,196,108` at card-relative `56,120`, radius 28;
- orange 3/8-turn arc, width 4, radius 40;
- two AA lines at card-relative y 92 and 108;
- a 12x12 nine-patch stretched to `160x64`, with red corners
  `212,52,52`, green edges `52,188,92` and a blue centre `44,104,236`.

The kernel readback checks nine exact pixels and the left/right frame
background, and requires damage to be exactly **1 rectangle / 76,800 pixels**
(the whole card and nothing outside it). One observed run printed:

```
  raster API    : rounded-rect circle line arc gradient shadow nine-patch
  raster card   : PASS 320x240 at 480,280, snapshot 0x792b55ac
  raster damage : PASS (1 rect(s), 76800 px)
  raster bench  : PASS 1920x1080 rgb565, 500 primitives, min 3444 us median 3505 us max 3747 us
  raster heap   : PASS allocated 4147200 B, used 0->0 B, largest free 8388584->8388584 B
  raster frames : PASS 2500/2500 primitive centres, five timed frames
  raster verdict: PASS
```

The card snapshot is diagnostic, not asserted: the raw framebuffer snapshot has
varied between boots while the checked pixels and damage stayed exact. The
harness therefore asserts the pixels and the independently captured QEMU
screendump, not a boot-specific CRC.

The harness reads the screendump independently with Pillow and checks the
gradient, accent, circle, arc, line, nine-patch centre/corner/edge and both
outside pixels. It archives `docs/screenshots/raster52-card.png`.

## 1080p / 500-primitive benchmark

The benchmark allocates **1920x1080 RGB565 = 4,147,200 bytes** from the kernel
heap, clears it outside the timed window, and draws **500 primitives** in a
25x20 grid: 100 rounded 8x8 chips (radius 2) and 400 filled 8x8 chips. Five
frames are timed; frame setup and the 4 MiB clear are excluded. IRQs are masked
inside the timing window so scheduler ticks and migration cannot split a
primitive or add an outlier. After each frame the kernel reads back all 500
primitive centres plus the background; all 2,500 checks over five frames must
match the RGB565 quantised colours. The heap is freed and must return
`used 0 -> 0` and the original largest free block.

Observed release runs in QEMU 8.2.2 on this host:

| run | min | median | max |
|---|---:|---:|---:|
| observed harness run | 3,530 us | 3,565 us | 3,624 us |
| earlier observed run | 3,444 us | 3,505 us | 3,747 us |
| IRQ-masked five-boot probe | 3,374–3,474 us | 3,434–3,704 us | 3,650–3,889 us |

The done criterion is met on the **median**: **3.5 ms for a 1920x1080 frame with
500 primitives**, under the 8 ms target. The minimum is also under 8 ms in every
observed run. This is a release-build claim; the standard debug kernel measured
about **12–13 ms** for the same 500 chips, which is why the harness documents
`zig build -Drelease=true`.

Honest limits: this proves **500 draw calls / primitives**, not a full-screen
fill. The chips are small (8x8). An earlier 64x40 rounded-chip version of the
same 500-primitive layout measured roughly **80 ms** in a release QEMU build,
so the 8 ms figure must not be read as 500 large cards or a full-screen
composite. QEMU TCG is also not hardware: this is not a native Cortex-A53
measurement, and the vector stores were not disassembled into NEON
instructions. The 1080p surface is RGB565 because the 8 MiB heap cannot hold a
1920x1080 RGBA frame (8,294,400 bytes) plus allocator metadata; 32-bit 1080p
compositing is not claimed. No dithering is applied, so RGB565 colours are
quantised.

## Negative control

`raster inject` arms a test-only write of magenta `255,0,255` at the verified
green-circle pixel. The next `raster test` must print:

```
  raster pixels : ... circle=0xffff00ff ...
  raster card   : FAIL ...
  raster verdict: FAIL
```

and the harness must see the magenta pixel in a second screendump. `raster
repair` clears the hook; the final test passes again. The benchmark still
passes in the injected run, which is expected: corruption is applied to the
card, and the overall verdict must still be FAIL. This proves the harness is
sensitive to a broken pixel rather than trusting the printed success line.

## Regression sweep

All fourteen earlier harnesses were run one at a time on the phase-52 tree.
Observed results are recorded in `PLAN.md` and `README.md`; none of their
assertions, counts, CRCs or timeouts was changed. In particular the sale-log
chain CRC remains boot-uptime dependent (`0xd197cd8e` in the phase-48 run,
`0xf8cd1815` in the phase-50 run) and is not asserted. The storage49 corruption
fixture hit a transient virtio format timeout on its first run; the isolated
rerun passed with the same assertions, the same known flake documented for phase
49, not a phase-52 regression.
