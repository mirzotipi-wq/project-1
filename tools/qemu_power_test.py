#!/usr/bin/env python3
"""Phase 40 power-management evidence harness.

The script boots the real Cassa aarch64 kernel under QEMU and observes the
kernel through its serial console. It covers the phase promises end to end:

  * an armed i6300ESB watchdog resets a deliberately hung kernel, and the next
    boot reports the watchdog reset with an unclean journal;
  * a file written before the hang is still readable and the FAT32 volume is
    consistent after the reset;
  * `power poweroff` flushes, disarms the watchdog, exits QEMU, and the next
    boot reports a clean shutdown with the file intact;
  * `power brownout` runs the board hooks and takes the same safe shutdown
    path, with a brownout record on the next boot;
  * the thermal ladder throttles the CPU (normal versus critical benchmark),
    records idle injection, and clears back to normal;
  * a machine with neither a watchdog nor a disk boots, reports both
    degradations, refuses `power hang`, and passes `power selftest`;
  * a framebuffer dashboard screenshot for the phase evidence.

Usage:  python3 tools/qemu_power_test.py [--keep]
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_power_test.py
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "zig-out" / "bin" / "cassa.bin"
SHOT_DIR = ROOT / "docs" / "screenshots"

QEMU = os.environ.get("QEMU") or str(Path.home() / "local/usr/bin/qemu-system-aarch64")
if not Path(QEMU).exists():
    QEMU = shutil.which("qemu-system-aarch64") or QEMU
LIB = os.environ.get("QEMU_LIB") or str(Path.home() / "local/usr/lib/x86_64-linux-gnu")

COMMON = [
    "-machine", "virt", "-cpu", "cortex-a53", "-m", "512M", "-smp", "4",
    "-display", "none", "-nic", "none",
    "-global", "virtio-mmio.force-legacy=false",
    "-device", "bochs-display,romfile=,xres=1280,yres=800",
]

# A 65 MiB disk with one bootable 64 MiB FAT32 partition.  This is deliberately
# generated here rather than taken from the host: the harness must be
# reproducible on a machine that has no partitioning tools.
SECTOR = 512
PART_START = 2048
PART_SECTORS = 131072
RESERVED = 32
FAT_COUNT = 2
SECTORS_PER_CLUSTER = 1


class Failure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def log(message: str) -> None:
    print(message, flush=True)


def make_fat32_disk(path: Path) -> None:
    total_sectors = PART_START + PART_SECTORS
    image = bytearray(total_sectors * SECTOR)

    # MBR: one partition entry at offset 446.
    entry = 446
    image[entry + 0] = 0x00              # not bootable
    image[entry + 1:entry + 4] = b"\xfe\xff\xff"
    image[entry + 4] = 0x0C              # FAT32 LBA
    image[entry + 5:entry + 8] = b"\xfe\xff\xff"
    image[entry + 8:entry + 12] = PART_START.to_bytes(4, "little")
    image[entry + 12:entry + 16] = PART_SECTORS.to_bytes(4, "little")
    image[510:512] = b"\x55\xaa"

    # FAT size must satisfy the FAT32 cluster limit and be large enough for
    # every cluster. Iterate upward from one sector: this is the monotonic
    # solution used by mkfs.fat for this geometry (1024 sectors, not 1008).
    fat_sectors = 1
    while True:
        data_sectors = PART_SECTORS - RESERVED - FAT_COUNT * fat_sectors
        clusters = data_sectors // SECTORS_PER_CLUSTER
        needed = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
        if needed <= fat_sectors:
            break
        fat_sectors = needed
    data_sectors = PART_SECTORS - RESERVED - FAT_COUNT * fat_sectors
    clusters = data_sectors // SECTORS_PER_CLUSTER

    def vbr(offset: int) -> None:
        b = image[offset:offset + SECTOR]
        b[0:3] = b"\xeb\x58\x90"
        b[3:11] = b"CASSA   "
        b[11:13] = SECTOR.to_bytes(2, "little")
        b[13] = SECTORS_PER_CLUSTER
        b[14:16] = RESERVED.to_bytes(2, "little")
        b[16] = FAT_COUNT
        b[17:19] = (0).to_bytes(2, "little")       # root entries
        b[19:21] = (0).to_bytes(2, "little")       # total sectors (16-bit)
        b[21] = 0xF8                                # media
        b[22:24] = (0).to_bytes(2, "little")       # FAT size (16-bit)
        b[24:26] = (32).to_bytes(2, "little")
        b[26:28] = (64).to_bytes(2, "little")
        b[28:32] = PART_START.to_bytes(4, "little")
        b[32:36] = PART_SECTORS.to_bytes(4, "little")
        b[36:40] = fat_sectors.to_bytes(4, "little")
        b[40:42] = (0).to_bytes(2, "little")       # extended flags
        b[42:44] = (0).to_bytes(2, "little")       # filesystem version
        b[44:48] = (2).to_bytes(4, "little")       # root cluster
        b[48:50] = (1).to_bytes(2, "little")       # FSInfo sector
        b[50:52] = (6).to_bytes(2, "little")       # backup boot sector
        b[64] = 0x80
        b[66] = 0x29
        b[67:71] = (0xCA55A).to_bytes(4, "little")
        b[71:82] = b"CASSA      "
        b[82:90] = b"FAT32   "
        b[510:512] = b"\x55\xaa"
        image[offset:offset + SECTOR] = b

    part_offset = PART_START * SECTOR
    vbr(part_offset)
    vbr((PART_START + 6) * SECTOR)  # backup boot sector

    def fsinfo(offset: int) -> None:
        b = image[offset:offset + SECTOR]
        b[0:4] = (0x41615252).to_bytes(4, "little")
        b[484:488] = (0x61417272).to_bytes(4, "little")
        b[488:492] = (clusters - 1).to_bytes(4, "little")  # root uses one
        b[492:496] = (3).to_bytes(4, "little")
        b[508:512] = (0xAA550000).to_bytes(4, "little")
        image[offset:offset + SECTOR] = b

    fsinfo((PART_START + 1) * SECTOR)
    fsinfo((PART_START + 7) * SECTOR)  # backup FSInfo

    def fat_at(sector: int) -> int:
        return (PART_START + RESERVED + sector) * SECTOR

    for copy in range(FAT_COUNT):
        base = fat_at(copy * fat_sectors)
        image[base + 0:base + 4] = (0x0FFFFFF8).to_bytes(4, "little")
        image[base + 4:base + 8] = (0x0FFFFFFF).to_bytes(4, "little")
        image[base + 8:base + 12] = (0x0FFFFFFF).to_bytes(4, "little")  # root

    path.write_bytes(image)
    log(f"      disk: {path} ({len(image) // (1024 * 1024)} MiB, "
        f"{clusters} clusters, FAT {fat_sectors} sectors)")


def wait_socket(path: str, timeout: float = 15.0) -> socket.socket:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
            return sock
        except OSError as exc:
            last = exc
            time.sleep(0.03)
    raise Failure(f"did not connect to {path}: {last}")


class Serial:
    def __init__(self, path: str):
        self.sock = wait_socket(path)
        self.sock.settimeout(0.2)
        self.buffer = ""
        self.decoder = "utf-8"

    def pump(self) -> bool:
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return False
        if not data:
            return False
        self.buffer += data.decode(errors="replace")
        return True

    def drain(self, seconds: float = 0.25) -> str:
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.pump()
        out = self.buffer
        self.buffer = ""
        return out

    def until(self, needle: str, timeout: float = 15.0) -> str:
        deadline = time.time() + timeout
        while time.time() < deadline:
            index = self.buffer.find(needle)
            if index >= 0:
                end = index + len(needle)
                found = self.buffer[:end]
                self.buffer = self.buffer[end:]
                return found
            self.pump()
        raise Failure(f"timed out waiting for {needle!r}; tail:\n{self.buffer[-3000:]}")

    def send(self, line: str) -> None:
        self.sock.sendall(line.encode() + b"\n")


class Qmp:
    def __init__(self, path: str):
        self.sock = wait_socket(path)
        self.file = self.sock.makefile("rwb")
        self._read()  # greeting
        self.call("qmp_capabilities")

    def _read(self) -> dict:
        line = self.file.readline()
        if not line:
            raise Failure("QMP closed unexpectedly")
        message = json.loads(line)
        if "error" in message:
            raise Failure(f"QMP error: {message['error']}")
        return message

    def call(self, name: str, arguments: dict | None = None):
        request = {"execute": name}
        if arguments is not None:
            request["arguments"] = arguments
        self.file.write(json.dumps(request).encode() + b"\n")
        self.file.flush()
        while True:
            message = self._read()
            if "return" in message:
                return message["return"]

    def screendump(self, path: Path) -> None:
        self.call("screendump", {"filename": str(path)})


class Machine:
    def __init__(self, tag: str, disk: bool, watchdog: bool, allow_reboot: bool = False,
                 disk_path: Path | None = None):
        self.tag = tag
        self.dir = Path(tempfile.mkdtemp(prefix=f"cassa-power-{tag}-"))
        self.serial_path = str(self.dir / "serial.sock")
        self.qmp_path = str(self.dir / "qmp.sock")
        self.disk_path = disk_path if disk_path is not None else self.dir / "phase40.img"
        if disk and disk_path is None:
            make_fat32_disk(self.disk_path)
        env = os.environ.copy()
        if Path(LIB).is_dir():
            env["LD_LIBRARY_PATH"] = LIB + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
        argv = [QEMU, *COMMON]
        if watchdog:
            argv += ["-device", "i6300esb,id=wdt0", "-watchdog-action", "reset"]
        if not allow_reboot:
            argv += ["-no-reboot"]
        if disk:
            argv += [
                "-drive", f"if=none,file={self.disk_path},format=raw,id=hd0",
                "-device", "virtio-blk-device,drive=hd0",
            ]
        argv += [
            "-serial", f"unix:{self.serial_path},server=on,wait=off",
            "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
            "-kernel", str(KERNEL),
        ]
        log(f"[{tag}] starting qemu (disk={disk}, watchdog={watchdog}, reboot={allow_reboot})")
        self.proc = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        self.serial = Serial(self.serial_path)
        self.qmp = Qmp(self.qmp_path)
        self.serial_commands = 0
        # SMP boot logs can interleave with the shell's `cassa> ` prompt. Wait
        # for the shell thread, let the last logs settle, then prove the shell
        # is reading input with an echoed sentinel.
        self.boot = self.serial.until("shell    thread", 30.0)
        self.boot += self.ready_handshake()
        log(f"[{tag}] booted to shell prompt")

    def ready_handshake(self) -> str:
        time.sleep(0.3)
        token = "__CASSA_READY__"
        self.serial.send("echo " + token)
        first = self.serial.until(token, 10.0)
        second = self.serial.until(token, 10.0)
        return first + second

    def cmd(self, line: str, timeout: float = 20.0) -> str:
        self.serial.drain()
        self.serial_commands += 1
        token = f"__CASSA_DONE_{self.serial_commands}__"
        self.serial.send(line)
        self.serial.send("echo " + token)
        first = self.serial.until(token, timeout)
        second = self.serial.until(token, timeout)
        return first + second

    def trigger(self, line: str, needle: str, timeout: float = 15.0) -> str:
        self.serial.drain()
        self.serial.send(line)
        return self.serial.until(needle, timeout)

    def wait_reboot(self, timeout: float = 20.0) -> str:
        reboot = self.serial.until("CASSA POS OS", timeout)
        boot = reboot + self.serial.until("shell    thread", timeout)
        return boot + self.ready_handshake()

    def wait_exit(self, timeout: float = 15.0) -> int:
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            raise Failure(f"[{self.tag}] QEMU did not exit after shutdown")

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def assert_fat_consistent(text: str) -> None:
    check("consistent" in text, f"FAT check did not report consistent:\n{text[-2000:]}")
    check("INCONSISTENT" not in text, f"FAT check reported an inconsistent volume:\n{text[-2000:]}")


def assert_file(machine: Machine, name: str, content: str) -> None:
    out = machine.cmd(f"fat cat {name}")
    check(content in out, f"{name} content missing after power event:\n{out[-2000:]}")
    check("byte(s)" in out, f"{name} byte count missing:\n{out[-2000:]}")
    assert_fat_consistent(machine.cmd("fat check"))


def scenario_watchdog() -> None:
    log("[watchdog] forced hang resets the machine and preserves data")
    machine = Machine("watchdog", disk=True, watchdog=True, allow_reboot=True)
    try:
        info = machine.cmd("power info")
        check("i6300ESB armed" in info, "watchdog was not armed:\n" + info[-2000:])
        wrote = machine.cmd("fat put WATCHDOG.TXT watchdog survived")
        check("wrote WATCHDOG.TXT" in wrote, "could not write the pre-hang file:\n" + wrote[-2000:])
        flush = machine.cmd("power flush")
        check("journal and device synced" in flush, "pre-hang flush failed:\n" + flush[-2000:])

        # No command can wait for its prompt here: the shell intentionally
        # abandons the CPU and only the hardware watchdog brings it back.
        machine.trigger("power hang", "watchdog should reset in 4000 ms", 10.0)
        boot = machine.wait_reboot(20.0)
        check("previous boot was a watchdog reset" in boot,
              "the second boot did not report the watchdog reset:\n" + boot[-3000:])
        check("journal history is unclean" in boot,
              "the second boot did not flag the unclean journal:\n" + boot[-3000:])

        info = machine.cmd("power info")
        check("last reset  : hardware watchdog reset" in info,
              "power info did not report the watchdog reset:\n" + info[-2000:])
        check("watchdog_boot" in info, "the watchdog boot record is missing:\n" + info[-2000:])
        assert_file(machine, "WATCHDOG.TXT", "watchdog survived")
        log("      reset observed; journal unclean; file and FAT volume intact")
    finally:
        machine.close()


def scenario_graceful() -> None:
    log("[graceful] poweroff flushes, disarms and exits; next boot is clean")
    disk = Path(tempfile.mkdtemp(prefix="cassa-power-graceful-disk-")) / "phase40.img"
    make_fat32_disk(disk)
    machine = Machine("graceful", disk=True, watchdog=True, disk_path=disk)
    try:
        wrote = machine.cmd("fat put GRACEFUL.TXT graceful shutdown")
        check("wrote GRACEFUL.TXT" in wrote, "could not write the graceful file:\n" + wrote[-2000:])
        machine.trigger("power poweroff", "clean shutdown complete; PSCI SYSTEM_OFF", 10.0)
        check(machine.wait_exit(15.0) == 0, "QEMU did not exit cleanly on poweroff")
    finally:
        machine.close()

    machine = Machine("graceful-check", disk=True, watchdog=True, disk_path=disk)
    try:
        check("previous shutdown: clean" in machine.boot,
              "the boot after poweroff did not report a clean shutdown:\n" + machine.boot[-3000:])
        info = machine.cmd("power info")
        check("last reset  : clean shutdown" in info,
              "power info did not report the clean shutdown:\n" + info[-2000:])
        journal = machine.cmd("power journal")
        check("clean_shutdown" in journal, "clean shutdown journal record is missing:\n" + journal[-2000:])
        assert_file(machine, "GRACEFUL.TXT", "graceful shutdown")
        selftest = machine.cmd("power selftest", 30.0)
        check("power selftest : PASS" in selftest,
              "power self-test failed on real watchdog/journal hardware:\n" + selftest[-3000:])
        check("FAIL" not in selftest, "power self-test reported a failure:\n" + selftest[-3000:])
        log("      exit code 0; clean journal; file and FAT volume intact; selftest PASS")
    finally:
        machine.close()


def scenario_brownout() -> None:
    log("[brownout] detector hooks flush and power off; next boot records it")
    disk = Path(tempfile.mkdtemp(prefix="cassa-power-brownout-disk-")) / "phase40.img"
    make_fat32_disk(disk)
    machine = Machine("brownout", disk=True, watchdog=True, disk_path=disk)
    try:
        wrote = machine.cmd("fat put BROWNOUT.TXT brownout survived")
        check("wrote BROWNOUT.TXT" in wrote, "could not write the brownout file:\n" + wrote[-2000:])
        out = machine.trigger("power brownout", "clean shutdown complete; PSCI SYSTEM_OFF", 10.0)
        check("brown-out shutdown: 1 hook(s) ran" in out,
              "the brownout hook did not run:\n" + out[-2000:])
        check(machine.wait_exit(15.0) == 0, "QEMU did not exit cleanly on brownout")
    finally:
        machine.close()

    machine = Machine("brownout-check", disk=True, watchdog=True, disk_path=disk)
    try:
        check("previous shutdown: clean" in machine.boot,
              "the boot after brownout was not clean:\n" + machine.boot[-3000:])
        journal = machine.cmd("power journal")
        check("brownout" in journal, "the brownout journal record is missing:\n" + journal[-2000:])
        assert_file(machine, "BROWNOUT.TXT", "brownout survived")
        log("      hook ran; exit code 0; brownout record; file and FAT volume intact")
    finally:
        machine.close()


def benchmark_ms(text: str) -> int:
    match = re.search(r"bench\s*:\s*\d+ iteration\(s\) in (\d+) ms", text)
    check(match is not None, "could not parse the thermal benchmark:\n" + text[-1200:])
    return int(match.group(1))


def scenario_thermal() -> None:
    log("[thermal] ladder throttles, idle injection is visible, clear restores normal")
    machine = Machine("thermal", disk=False, watchdog=True)
    try:
        normal = machine.cmd("thermal bench", 30.0)
        normal_ms = benchmark_ms(normal)
        check("normal/0%" in normal, "the cool benchmark was not at normal/0%:\n" + normal)

        set_out = machine.cmd("thermal set 96000")
        check("critical" in set_out and "75%" in set_out,
              "thermal set did not enter critical/75%:\n" + set_out[-1500:])
        hot = machine.cmd("thermal bench", 30.0)
        hot_ms = benchmark_ms(hot)
        check("critical/75%" in hot, "the hot benchmark was not throttled:\n" + hot)

        info = machine.cmd("thermal info")
        check("(3/4)" in info, "idle quarters did not reach 3/4:\n" + info[-1500:])
        idle = re.search(r"(\d+) idle tick\(s\)", info)
        check(idle is not None and int(idle.group(1)) > 0,
              "idle injection was never counted:\n" + info[-1500:])
        check(hot_ms > normal_ms,
              f"throttled benchmark ({hot_ms} ms) was not slower than normal ({normal_ms} ms)")

        cleared = machine.cmd("thermal clear")
        check("normal" in cleared and "42.000 C" in cleared,
              "thermal clear did not return the zone to normal:\n" + cleared[-1500:])
        verdict = machine.cmd("thermal selftest")
        check("PASS" in verdict and "FAIL" not in verdict, "thermal self-test failed:\n" + verdict[-1500:])
        log(f"      normal {normal_ms} ms -> critical {hot_ms} ms "
            f"({hot_ms / normal_ms:.2f}x); idle counters advanced; clear restored 42.000 C")
    finally:
        machine.close()


def scenario_fallback() -> None:
    log("[fallback] no watchdog and no disk still boots, reports and passes selftests")
    machine = Machine("fallback", disk=False, watchdog=False)
    try:
        info = machine.cmd("power info")
        check("absent (graceful fallback)" in info,
              "the no-watchdog boot did not report the fallback:\n" + info[-2000:])
        check("no block device; power events are memory-only" in info,
              "the no-disk boot did not report the memory-only journal:\n" + info[-2000:])
        check("result: PASS" in machine.boot, "boot self-tests failed without power hardware")

        selftest = machine.cmd("power selftest")
        check("power selftest : PASS" in selftest, "power self-test failed:\n" + selftest[-2500:])
        check(selftest.count("OK (degraded)") >= 2,
              "the missing watchdog/journal were not reported as degraded:\n" + selftest[-2500:])
        check("FAIL" not in selftest, "a degraded power self-test reported a failure:\n" + selftest[-2500:])

        wdt = machine.cmd("watchdog info")
        check("watchdog    : absent" in wdt, "watchdog info claimed hardware:\n" + wdt[-1500:])
        hang = machine.cmd("power hang")
        check("refused: no hardware watchdog is armed" in hang,
              "power hang was not refused without a watchdog:\n" + hang[-1500:])
        log("      absent watchdog and journal reported; selftest PASS; hang refused")
    finally:
        machine.close()


def scenario_screenshot() -> None:
    log("[screenshot] power/thermal dashboard")
    machine = Machine("screenshot", disk=True, watchdog=True)
    try:
        machine.cmd("power selftest")
        machine.cmd("power flush")
        machine.cmd("thermal set 96000")
        machine.cmd("power viz 5", 15.0)
        shot = SHOT_DIR / "phase40-power.png"
        ppm = machine.dir / "power-viz.ppm"
        machine.qmp.screendump(ppm)
        deadline = time.time() + 5
        while not ppm.exists() and time.time() < deadline:
            time.sleep(0.05)
        check(ppm.exists(), "screendump did not produce a frame")
        SHOT_DIR.mkdir(parents=True, exist_ok=True)
        try:
            from PIL import Image
        except ImportError as exc:
            raise Failure(f"Pillow is required to convert the dashboard frame: {exc}")
        with Image.open(ppm) as image:
            check(image.width >= 1280 and image.height >= 800,
                  f"dashboard frame is unexpectedly small: {image.size}")
            image.save(shot)
        log(f"      evidence: {shot.relative_to(ROOT)}")
    finally:
        machine.close()


def main() -> int:
    if not KERNEL.exists():
        log(f"missing {KERNEL}; run `zig build` first")
        return 2
    if not Path(QEMU).exists():
        log(f"missing QEMU ({QEMU}); set QEMU=...")
        return 2

    scenarios = [
        ("watchdog", scenario_watchdog),
        ("graceful", scenario_graceful),
        ("brownout", scenario_brownout),
        ("thermal", scenario_thermal),
        ("fallback", scenario_fallback),
        ("screenshot", scenario_screenshot),
    ]
    try:
        for name, scenario in scenarios:
            scenario()
            log(f"[ok]   {name}")
    except Failure as exc:
        log(f"[FAIL] {exc}")
        return 1
    log("phase 40 power evidence: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
