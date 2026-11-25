#!/usr/bin/env python3
"""Phase 39 USB regression harness.

Boots the Cassa aarch64 kernel under QEMU with a real xHCI controller and
exercises the paths the phase promises:

  * enumeration of a USB keyboard and absolute tablet, with QMP keystrokes,
    pointer motion and buttons reaching the phase 38 input stream;
  * a barcode scanner burst (HID keyboard digits + CR) committing a scan;
  * two keyboard unplug/replug cycles through QMP;
  * a keyboard behind a USB hub;
  * an FTDI serial bridge with data in both directions, across a replug;
  * a boot with no xHCI controller at all.

The script is deliberately black-box: it talks to the kernel through the same
serial console and QMP monitor a person would use. It exits non-zero on the
first failed expectation and prints the evidence it checked.

Usage:  python3 tools/qemu_usb_test.py
        QEMU=/path/to/qemu-system-aarch64 python3 tools/qemu_usb_test.py
"""

from __future__ import annotations

import json
import os
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
    "-no-reboot",
]


class Failure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def wait_for(path: str, timeout: float = 10.0) -> socket.socket:
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


class Qmp:
    def __init__(self, path: str):
        self.sock = wait_for(path)
        self.file = self.sock.makefile("rwb")
        self._read()
        self.call("qmp_capabilities")

    def _read(self):
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

    def hmp(self, command: str) -> str:
        return self.call("human-monitor-command", {"command-line": command})

    def key(self, key: str) -> None:
        self.hmp("sendkey " + key)

    def mouse_button(self, down: bool) -> None:
        self.hmp(f"mouse_button 1 {1 if down else 0}")

    def burst(self, keys: list[str]) -> None:
        """One QMP send-key call: a scanner-like burst, not slow typing.

        Only use this while the guest is at the normal shell prompt: QEMU's
        send-key waits on its hold timer and does not return during the live
        input view.
        """
        self.call("send-key", {
            "keys": [{"type": "qcode", "data": key} for key in keys],
            "hold-time": 20,
        })

    def pointer(self, x: int, y: int) -> None:
        self.call("input-send-event", {"events": [
            {"type": "abs", "data": {"axis": "x", "value": x}},
            {"type": "abs", "data": {"axis": "y", "value": y}},
        ]})

    def button(self, down: bool) -> None:
        self.call("input-send-event", {"events": [
            {"type": "btn", "data": {"down": down, "button": "left"}},
        ]})

    def add(self, driver: str, ident: str, **props) -> None:
        arguments = {"driver": driver, "id": ident, "bus": "xhci.0"}
        arguments.update(props)
        self.call("device_add", arguments)

    def delete(self, ident: str) -> None:
        self.call("device_del", {"id": ident})

    def screendump(self, path: Path) -> None:
        self.call("screendump", {"filename": str(path)})


class Guest:
    def __init__(self, extra: list[str], tty_path: str | None = None,
                 connect_tty: bool = False):
        self.dir = tempfile.mkdtemp(prefix="cassa-usb-test-")
        self.serial_path = os.path.join(self.dir, "serial")
        qmp_path = os.path.join(self.dir, "qmp")
        env = os.environ.copy()
        if Path(LIB).is_dir():
            env["LD_LIBRARY_PATH"] = LIB + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
        argv = [QEMU, *COMMON, "-serial", f"unix:{self.serial_path},server=on,wait=off"]
        if tty_path:
            argv += ["-chardev", f"socket,id=usbser,path={tty_path},server=on,wait=off"]
        argv += extra
        argv += ["-qmp", f"unix:{qmp_path},server=on,wait=off", "-kernel", str(KERNEL)]
        self.proc = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        self.tty = wait_for(tty_path) if connect_tty and tty_path else None
        self.serial = wait_for(self.serial_path)
        self.serial.settimeout(0.2)
        self.qmp = Qmp(qmp_path)
        self.boot = self.until("cassa>", timeout=30.0)

    def read(self, seconds: float = 0.35) -> str:
        end = time.time() + seconds
        out = ""
        while time.time() < end:
            try:
                chunk = self.serial.recv(65536)
                if not chunk:
                    break
                out += chunk.decode(errors="replace")
            except socket.timeout:
                pass
        return out

    def until(self, needle: str, timeout: float = 4.0) -> str:
        deadline = time.time() + timeout
        out = ""
        while time.time() < deadline:
            try:
                chunk = self.serial.recv(65536)
                if not chunk:
                    break
                out += chunk.decode(errors="replace")
                if needle in out:
                    return out
            except socket.timeout:
                pass
        raise Failure(f"timed out waiting for {needle!r}; last output:\n{out[-3000:]}")

    def drain(self) -> None:
        self.read(0.15)

    def cmd(self, line: str, timeout: float = 3.0) -> str:
        self.drain()
        self.serial.sendall(line.encode() + b"\n")
        return self.until("cassa>", timeout=timeout)

    def usb(self) -> str:
        return self.cmd("usb")

    def devices(self) -> int:
        for line in self.usb().splitlines():
            if "usb devices  :" in line and "/8 attached" in line:
                field = line.split(":", 1)[1].strip().split("/")[0]
                try:
                    return int(field)
                except ValueError:
                    pass
        return -1

    def wait_devices(self, count: int, timeout: float = 8.0) -> str:
        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            last = self.usb()
            if f"usb devices  : {count}/8" in last:
                return last
            time.sleep(0.1)
        raise Failure(f"expected {count} USB devices; last usb output:\n{last[-3000:]}")

    def close(self) -> None:
        if self.tty:
            self.tty.close()
        self.serial.close()
        self.proc.terminate()
        try:
            self.proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


def scenario_hid() -> None:
    print("[hid] keyboard, tablet, barcode and replug")
    guest = Guest([
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-kbd,id=kbd",
        "-device", "usb-tablet,id=tab",
    ])
    try:
        info = guest.wait_devices(2)
        check("QEMU USB Keyboard" in info, "keyboard not reported")
        check("QEMU USB Tablet" in info, "tablet not reported")
        check("usb 0 -> input 0" in info and "usb 1 -> input 1" in info,
              "USB devices are not bound to the input core")
        check("0 errors" in info, "controller reported transfer errors during enumeration")
        selftest = guest.cmd("usb selftest")
        check("usb selftest : PASS" in selftest, "USB self-test did not pass:\n" + selftest[-2000:])
        check("FAIL" not in selftest, "a USB class driver failed its self-test:\n" + selftest[-2000:])

        # Scanner: HID keyboard digits delivered as a fast burst then CR.
        # Widen the gap for the automated burst so a loaded QEMU host cannot
        # stretch report delivery past the product's 40 ms default; restore it
        # afterwards for the live screenshot and the remaining checks.
        guest.cmd("input gap 250")
        guest.qmp.burst(["1", "2", "3", "4", "ret"])
        guest.read(0.5)
        scan = guest.cmd("input info")
        check("barcode '1234'" in scan, "barcode burst was not committed:\n" + scan[-2500:])
        check("scans       : 1 committed" in scan, "scanner counter did not commit")
        check("0 timeouts" in scan.split("scans", 1)[1].split("scan timing", 1)[0],
              "scanner burst timed out")
        guest.cmd("input gap 40")

        # Ordinary typing through the same USB keyboard.
        for key in ["f1", "f2", "a", "b", "c"]:
            guest.qmp.key(key)
            time.sleep(0.08)
        guest.qmp.key("ret")
        guest.read(0.4)
        typed = guest.cmd("input info")
        for token in ["key A", "key B", "key C"]:
            check(token in typed, f"missing {token} in input events:\n" + typed[-2500:])
        check("QEMU USB Keyboard keyboard events" in typed,
              "keyboard did not reach the phase 38 input core")

        # Absolute pointer + button from the USB tablet.
        for x, y in [(4000, 3000), (18000, 12000), (12000, 8000)]:
            guest.qmp.pointer(x, y)
            time.sleep(0.12)
        guest.qmp.button(True)
        guest.qmp.button(False)
        guest.read(0.3)
        pointer = guest.cmd("input info")
        check("pointer" in pointer and "button 1 down" in pointer,
              "tablet pointer/button did not reach input:\n" + pointer[-2500:])
        check("QEMU USB Tablet tablet events" in pointer,
              "tablet is not registered as an input device")

        # Two genuine unplug/replug cycles. The keyboard is removed from QEMU,
        # the kernel must release its slot and input device, then enumerate the
        # newly attached one on a fresh port and accept keys again.
        before = guest.usb()
        for cycle in range(1, 3):
            guest.qmp.delete("kbd" if cycle == 1 else f"kbd{cycle}")
            deadline = time.time() + 5
            removed = ""
            while time.time() < deadline:
                removed = guest.usb()
                if "QEMU USB Keyboard" not in removed:
                    break
                time.sleep(0.1)
            check("QEMU USB Keyboard" not in removed, f"cycle {cycle}: keyboard did not detach")
            check("1/8 attached" in removed, f"cycle {cycle}: device table did not shrink")
            check("removed" in removed and "0 removed" not in removed,
                  f"cycle {cycle}: kernel did not account for the removal:\n" + removed[-2000:])

            guest.qmp.add("usb-kbd", f"kbd{cycle + 1}")
            info = guest.wait_devices(2)
            check("QEMU USB Keyboard" in info, f"cycle {cycle}: keyboard did not re-enumerate")
            check(f"{cycle + 2} enumerated" in info,
                  f"cycle {cycle}: enumeration counter did not advance:\n" + info[-2000:])

            for key in ["x", "y", "z"]:
                guest.qmp.key(key)
                time.sleep(0.08)
            guest.qmp.key("ret")
            guest.read(0.4)
            events = guest.cmd("input info")
            for token in ["key X", "key Y", "key Z"]:
                check(token in events, f"cycle {cycle}: {token} missing after replug:\n" + events[-2200:])

        # The framebuffer shell keeps the boot splash until a screen-owning
        # command runs, so capture the live input monitor while USB events are
        # being decoded: the header names the USB devices and counters.
        shot = SHOT_DIR / "phase39-usb-input.png"
        ppm = Path(guest.dir) / "usb-screen.ppm"
        # Seed the monitor's 16-event history with one scan, four USB keys and
        # one pointer click, then open the view and capture it. No input is
        # injected while the view runs, so QMP stays responsive.
        guest.qmp.burst(["1", "2", "3", "4", "ret"])
        for key in ["f1", "f2", "f3", "f4"]:
            guest.qmp.key(key)
            time.sleep(0.08)
        guest.qmp.pointer(6000, 4000)
        guest.qmp.pointer(18000, 11000)
        guest.qmp.button(True)
        guest.qmp.button(False)
        time.sleep(0.25)
        guest.drain()
        guest.serial.sendall(b"input viz 5\n")
        # Let the view close on its own; it leaves the last monitor frame on
        # the framebuffer, and QMP screendump is reliable at an idle shell.
        guest.until("viz         : closed", timeout=9.0)
        guest.until("cassa>", timeout=3.0)
        guest.qmp.screendump(ppm)
        save_png(ppm, shot)
        print(f"      evidence: {shot.relative_to(ROOT)}")
        print(f"      initial: {before.splitlines()[0].strip()}")
    finally:
        guest.close()


def scenario_hub() -> None:
    print("[hub] keyboard behind an eight-port hub")
    guest = Guest([
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-hub,id=hub,bus=xhci.0",
        "-device", "usb-kbd,bus=xhci.0,port=1.1,id=hkbd",
        "-device", "usb-tablet,id=tab",
    ])
    try:
        info = guest.wait_devices(3)
        check("QEMU USB Hub [hub]" in info, "hub missing from device table")
        check("hub 8 ports, 1 child(ren)" in info, "hub child was not recorded")
        check("QEMU USB Keyboard [keyboard]" in info, "keyboard behind hub not enumerated")
        check("0 failed" in info, "a hub child failed to enumerate")

        for key in ["q", "w", "e"]:
            guest.qmp.key(key)
            time.sleep(0.08)
        guest.qmp.key("ret")
        guest.read(0.4)
        events = guest.cmd("input info")
        for token in ["key Q", "key W", "key E"]:
            check(token in events, f"hub keyboard did not deliver {token}:\n" + events[-2500:])
        check("hub scans" in info and "0 hub scans" not in info,
              "hub was never polled")
    finally:
        guest.close()


def scenario_serial() -> None:
    print("[serial] FTDI bulk bridge, both directions and replug")
    tty_path = os.path.join(tempfile.mkdtemp(prefix="cassa-usb-tty-"), "tty")
    guest = Guest([
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-kbd,id=kbd",
        "-device", "usb-tablet,id=tab",
        "-device", "usb-serial,chardev=usbser,id=ftdi,bus=xhci.0",
    ], tty_path=tty_path, connect_tty=True)
    try:
        info = guest.wait_devices(3)
        check("QEMU USB SERIAL [serial]" in info, "FTDI bridge not enumerated as serial")
        check("usb serial   : 1 device(s)" in info, "serial class driver did not bind")

        sent = guest.cmd("usb serial 0 send hello")
        check("sent 7 bytes" in sent, "serial send failed:\n" + sent[-1200:])
        payload = recv_exact(guest.tty, b"hello\r\n", 3.0)
        check(payload == b"hello\r\n", f"host received {payload!r}, expected hello CRLF")

        guest.tty.sendall(b"world\n")
        time.sleep(0.3)
        read = guest.cmd("usb serial 0 read")
        check("world" in read, "serial read did not return host data:\n" + read[-1200:])
        check("b1 00" not in read, "FTDI modem-status header leaked into payload:\n" + read[-1200:])

        # Replug the serial bridge; the chardev stays open.
        guest.qmp.delete("ftdi")
        guest.wait_devices(2)
        guest.qmp.add("usb-serial", "ftdi2", chardev="usbser")
        info = guest.wait_devices(3)
        check("QEMU USB SERIAL [serial]" in info, "serial did not re-enumerate after replug")
        check("4 enumerated" in info, "serial replug was not counted")
        sent = guest.cmd("usb serial 0 send again")
        check("sent 7 bytes" in sent, "serial send after replug failed:\n" + sent[-1200:])
        payload = recv_exact(guest.tty, b"again\r\n", 3.0)
        check(payload == b"again\r\n", f"post-replug host payload {payload!r}")
        guest.tty.sendall(b"second\n")
        time.sleep(0.3)
        read = guest.cmd("usb serial 0 read")
        check("second" in read, "serial read after replug failed:\n" + read[-1200:])
    finally:
        guest.close()


def scenario_nousb() -> None:
    print("[nousb] boot without an xHCI controller")
    guest = Guest([])
    try:
        check("result: PASS" in guest.boot, "boot self-test did not pass without USB")
        info = guest.usb()
        check("xHCI not present" in info, "USB stack claims a controller when none exists")
        check("0/8 attached" in info, "no-USB boot reports devices")
        check("none (controller absent)" in info, "no-USB boot did not report the absent controller")
        selftest = guest.cmd("usb selftest")
        check("no xHCI controller in this machine" in selftest, "USB self-test did not explain the absent controller")
        check("FAIL" not in selftest, "USB self-test failed on a no-USB machine")
    finally:
        guest.close()


def recv_exact(sock: socket.socket, expected: bytes, timeout: float) -> bytes:
    sock.settimeout(0.2)
    deadline = time.time() + timeout
    data = b""
    while time.time() < deadline:
        if expected in data:
            return expected
        try:
            chunk = sock.recv(1024)
            if not chunk:
                break
            data += chunk
        except socket.timeout:
            pass
    return data


def save_png(ppm: Path, png: Path) -> None:
    deadline = time.time() + 5
    while not ppm.exists() and time.time() < deadline:
        time.sleep(0.05)
    check(ppm.exists(), f"screendump did not produce {ppm}")
    SHOT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        from PIL import Image
    except ImportError as exc:
        raise Failure(f"Pillow is required to convert the screendump: {exc}")
    Image.open(ppm).save(png)


def main() -> int:
    if not KERNEL.exists():
        print(f"missing {KERNEL}; run `zig build` first", file=sys.stderr)
        return 2
    if not Path(QEMU).exists():
        print(f"missing QEMU ({QEMU}); set QEMU=...", file=sys.stderr)
        return 2
    scenarios = [scenario_hid, scenario_hub, scenario_serial, scenario_nousb]
    try:
        for scenario in scenarios:
            scenario()
            print(f"[ok]   {scenario.__name__}")
        print(f"USB scenarios: {len(scenarios)}/{len(scenarios)} PASS")
    except Failure as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    print("all phase 39 USB scenarios passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
