#!/usr/bin/env python3
"""Phase 44 CASSAFS page-cache evidence harness.

The real aarch64 kernel boots a formatted CASSAFS volume and mounts it through
the VFS. The harness drives the kernel's page-cache commands and proves:

  * mount + read traffic produces real 4 KiB hits/misses and readahead;
  * dropping the cache forces the next read from the medium;
  * a sale-sized VFS commit stays under the 100 ms phase-44 budget while a
    catalog read loop is interleaved (the POS checkout itself is a later phase);
  * write-back evictions are bounded and flushed, and the committed sale is
    byte-identical after a cache drop, unmount/remount and host verification.

Usage:  python3 tools/qemu_page_cache_test.py [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_page_cache_test.py
"""

from __future__ import annotations

import re
import shutil
import sys
import time
from pathlib import Path

from qemu_vfs_test import (
    PRODUCTS_CRC,
    PRODUCTS_SIZE,
    ROOT,
    SHOT_DIR,
    Machine,
    cat_summary,
    check,
    log,
    mount_ready,
    prepare_formatted,
)
from qemu_vfs_write_test import host_verify, shutdown_clean

CACHE_RE = re.compile(
    r"vfs cache\s+:\s+(\d+)/(\d+)\s+page\(s\) resident\s+\((\d+)% pressure\),\s+"
    r"(\d+)/(\d+) dirty, hit rate (\d+)% \((\d+) hit / (\d+) miss\)"
)
CACHE_IO_RE = re.compile(
    r"(\d+) read\(s\),\s+(\d+) write\(s\),\s+(\d+) eviction\(s\),\s+"
    r"(\d+) writeback\(s\),\s+(\d+) flush\(es\), readahead\s+"
    r"(\d+) read\(s\)/(\d+) hit\(s\)/(\d+) error\(s\)"
)
BENCH_RE = re.compile(
    r"vfs bench\s+:\s+(\d+) sale-sized commit\(s\), max (\d+) ms "
    r"\(budget 100 ms\), catalog (\d+) read\(s\)/(\d+) B, cache (\d+)% hit"
)


def cache_stats(output: str) -> dict[str, int]:
    match = CACHE_RE.search(output)
    check(match is not None, "vfs cache counters missing:\n" + output[-3000:])
    io = CACHE_IO_RE.search(output)
    check(io is not None, "vfs cache I/O counters missing:\n" + output[-3000:])
    return {
        "used": int(match.group(1)),
        "capacity": int(match.group(2)),
        "pressure": int(match.group(3)),
        "dirty": int(match.group(4)),
        "max_dirty": int(match.group(5)),
        "hit_rate": int(match.group(6)),
        "hits": int(match.group(7)),
        "misses": int(match.group(8)),
        "reads": int(io.group(1)),
        "writes": int(io.group(2)),
        "evictions": int(io.group(3)),
        "writebacks": int(io.group(4)),
        "flushes": int(io.group(5)),
        "readahead_reads": int(io.group(6)),
        "readahead_hits": int(io.group(7)),
        "readahead_errors": int(io.group(8)),
    }


def page_cache_scenario() -> None:
    work, disk = prepare_formatted("cache")
    machine = Machine("cache", disk)
    try:
        mount_ready(machine)

        initial = cache_stats(machine.cmd("vfs cache"))
        check(initial["capacity"] == 64, "page cache did not expose its 64-page bound")
        check(initial["max_dirty"] == 16, "page cache did not expose its 16-page dirty bound")
        check(initial["used"] > 0, "mount scan left the page cache empty")
        check(initial["hits"] + initial["misses"] > 0, "mount produced no cache traffic")
        log(
            f"      mount cache: {initial['used']}/{initial['capacity']} pages, "
            f"{initial['pressure']}% pressure, {initial['hit_rate']}% hit "
            f"({initial['hits']} hit / {initial['misses']} miss)"
        )

        flush = machine.cmd("vfs cache flush")
        check("dirty pages written back" in flush, "explicit cache flush failed:\n" + flush[-2000:])
        check("every resident page dropped" in machine.cmd("vfs cache drop"),
              "cache drop did not report a successful flush and invalidation")
        empty = cache_stats(machine.cmd("vfs cache"))
        check(empty["used"] == 0, "cache drop left resident pages")
        check(empty["dirty"] == 0, "cache drop left dirty pages")

        read = machine.cmd("vfs read /catalog/products.db 0 16")
        check("returned 16 byte(s)" in read and "sku,name,price_c" in read,
              "cold-cache range read returned the wrong bytes:\n" + read[-2500:])
        after_read = cache_stats(machine.cmd("vfs cache"))
        check(after_read["used"] > 0, "cold-cache read did not populate the cache")
        check(after_read["misses"] > empty["misses"], "cold-cache read did not miss")
        check(after_read["readahead_reads"] > empty["readahead_reads"],
              "cold-cache read did not issue readahead")
        check(after_read["readahead_errors"] == 0, "readahead reported an error")

        products = machine.cmd("vfs cat /catalog/products.db")
        psize, pcrc = cat_summary(products, "/catalog/products.db")
        check((psize, pcrc) == (PRODUCTS_SIZE, PRODUCTS_CRC),
              f"cached products.db read is {psize}/{pcrc}, expected {PRODUCTS_SIZE}/{PRODUCTS_CRC}")
        first_cat = cache_stats(machine.cmd("vfs cache"))
        products_again = machine.cmd("vfs cat /catalog/products.db")
        check(cat_summary(products_again, "/catalog/products.db") == (psize, pcrc),
              "second cached read changed the catalog CRC")
        second_cat = cache_stats(machine.cmd("vfs cache"))
        check(second_cat["hits"] > first_cat["hits"], "a repeated cat did not produce cache hits")
        check(second_cat["hit_rate"] > 0, "cache hit rate stayed at zero after a repeated cat")
        log(
            f"      cache read: {second_cat['hits']} hit / {second_cat['misses']} miss, "
            f"{second_cat['hit_rate']}% hit, {second_cat['readahead_reads']} readahead read(s)"
        )

        bench = machine.cmd("vfs cache bench", 45.0)
        match = BENCH_RE.search(bench)
        check(match is not None, "benchmark summary missing:\n" + bench[-3000:])
        commits = int(match.group(1))
        max_ms = int(match.group(2))
        catalog_reads = int(match.group(3))
        catalog_bytes = int(match.group(4))
        hit_rate = int(match.group(5))
        check(commits == 8, f"benchmark ran {commits} commits, expected 8")
        check(max_ms < 100, f"sale commit exceeded the 100 ms budget: {max_ms} ms")
        check(catalog_reads == 16 and catalog_bytes == 1264,
              f"catalog load was {catalog_reads} reads/{catalog_bytes} B, expected 16/1264")
        check("PASS" in bench, "benchmark did not report PASS:\n" + bench[-3000:])
        log(
            f"      sale commit: max {max_ms} ms / 100 ms budget, "
            f"catalog {catalog_reads} reads/{catalog_bytes} B, cache {hit_rate}% hit"
        )

        after_bench = cache_stats(machine.cmd("vfs cache"))
        check(after_bench["dirty"] == 0, "a committed sale left dirty cache pages")
        check(after_bench["evictions"] > 0, "the 64-page cache never evicted under the benchmark")
        check(after_bench["writebacks"] > 0, "the cache never wrote back a dirty page")
        check(after_bench["used"] <= 64, "cache exceeded its page bound")
        check(after_bench["writebacks"] + after_bench["evictions"] > 0, "cache pressure was not accounted")
        log(
            f"      pressure: {after_bench['used']}/{after_bench['capacity']} pages, "
            f"{after_bench['evictions']} evictions, {after_bench['writebacks']} writebacks, "
            f"{after_bench['flushes']} flushes"
        )

        sale = machine.cmd("vfs cat /receipts/sale44.tmp")
        ssize, scrc = cat_summary(sale, "/receipts/sale44.tmp")
        check(ssize == 33 and scrc == "0x12b569fa",
              f"sale file is {ssize}/{scrc}, expected 33/0x12b569fa")
        log(f"      sale file: {ssize} B, CRC32C {scrc} (asserted)")
        check("sale=43 sku=1001 qty=1 total=250" in sale, "sale payload is wrong")

        screenshot(machine)

        check("every resident page dropped" in machine.cmd("vfs cache drop"),
              "second cache drop failed")
        from_medium = machine.cmd("vfs cat /receipts/sale44.tmp")
        check(cat_summary(from_medium, "/receipts/sale44.tmp") == (ssize, scrc),
              "sale bytes are not intact after dropping the cache")
        check("sale=43 sku=1001 qty=1 total=250" in from_medium,
              "sale payload changed after cache drop")

        unmount = machine.cmd("vfs unmount")
        check("page cache flushed" in unmount, "unmount did not flush the page cache:\n" + unmount[-2500:])
        remount = mount_ready(machine)
        check("5 inode(s), 2 file(s), 158 data byte(s)" not in remount,
              "remount unexpectedly reverted to the demo-only tree")
        after_remount = machine.cmd("vfs cat /receipts/sale44.tmp")
        check(cat_summary(after_remount, "/receipts/sale44.tmp") == (ssize, scrc),
              "sale bytes changed across unmount/remount")
        check("6 inode(s), 3 file(s), 191 data byte(s)" in remount,
              "remount did not expose the sale file's counters:\n" + remount[-3000:])

        shutdown_clean(machine)
        verify = host_verify(disk)
        check("PASS" in verify, "host verifier did not accept the cached write path")
        log("      unmount/remount, cache drop and host verifier: PASS")
    finally:
        machine.close()
        if "--keep" not in sys.argv:
            shutil.rmtree(work, ignore_errors=True)


def screenshot(machine: Machine) -> None:
    machine.cmd("vfs viz 3", 15.0)
    shot = SHOT_DIR / "phase44-cache.png"
    ppm = machine.dir / "vfs-cache-viz.ppm"
    machine.qmp.screendump(ppm)
    deadline = time.time() + 5
    while not ppm.exists() and time.time() < deadline:
        time.sleep(0.05)
    check(ppm.exists(), "screendump did not produce a frame")
    SHOT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        from PIL import Image
    except ImportError as exc:
        raise RuntimeError(f"Pillow is required to convert the dashboard frame: {exc}") from exc
    with Image.open(ppm) as image:
        check(image.width >= 1280 and image.height >= 800,
              f"dashboard frame is unexpectedly small: {image.size}")
        image.save(shot)
    log(f"      evidence: {shot.relative_to(ROOT)}")


def main() -> int:
    try:
        page_cache_scenario()
    except Exception as exc:
        log(f"[FAIL] {exc}")
        return 1
    log("phase 44 page-cache evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
