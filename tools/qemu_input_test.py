#!/usr/bin/env python3
"""Phase 38 input evidence harness.

Boots Cassa under QEMU with the real virtio keyboard and tablet attached, drives
them through the monitor's `sendkey` / `mouse_move` / `mouse_button` commands and
reads the serial console, so the evidence is the kernel's own view of the
hardware rather than a host unit test.

Two runs:
  * with input devices: `input`, `input viz` (screenshot), keyboard typing,
    pointer motion, a scripted barcode burst and `input dump`, the HID decoder
    self-test, key remapping, then halt;
  * without input devices: the same kernel must boot, report no input devices
    and pass the boot self-tests.

Usage: python3 tools/qemu_input_test.py [--keep]
"""

import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QEMU = os.path.expanduser("~/local/usr/bin/qemu-system-aarch64")
LIB = os.path.expanduser("~/local/usr/lib/x86_64-linux-gnu")
KERNEL = os.path.join(ROOT, "zig-out", "bin", "cassa.bin")

BARCODE = "4006381333931"


def log(message):
    print(message, flush=True)


class Socket:
    def __init__(self, path, timeout=30.0):
        self.path = path
        self.buffer = ""
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        deadline = time.time() + timeout
        while True:
            try:
                self.sock.connect(path)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.05)
        self.sock.settimeout(0.2)

    def send(self, text):
        self.sock.sendall(text.encode())

    def _pump(self):
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return False
        if not data:
            return False
        self.buffer += data.decode(errors="replace")
        return True

    def wait_for(self, needle, timeout=60.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            index = self.buffer.find(needle)
            if index >= 0:
                end = index + len(needle)
                found = self.buffer[:end]
                self.buffer = self.buffer[end:]
                return found
            self._pump()
        raise TimeoutError(f"timed out waiting for {needle!r}; tail:\n{self.buffer[-1500:]}")

    def drain(self, seconds=0.3):
        deadline = time.time() + seconds
        while time.time() < deadline:
            self._pump()
        out = self.buffer
        self.buffer = ""
        return out


class Qmp:
    def __init__(self, path):
        self.sock = Socket(path)
        self.sock.wait_for("\n", 20)  # greeting
        self.command("qmp_capabilities")

    def send(self, message):
        self.sock.send(json.dumps(message) + "\n")

    def command(self, name, arguments=None):
        self.send({"execute": name, "arguments": arguments or {}})
        line = self.sock.wait_for("\n", 10)
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return {"raw": line}

    def pointer(self, x, y, press):
        events = [
            {"type": "abs", "data": {"axis": "x", "value": x}},
            {"type": "abs", "data": {"axis": "y", "value": y}},
        ]
        if press is not None:
            events.append({"type": "btn", "data": {"down": press, "button": "left"}})
        # QEMU 8.2 crashes when `device` names a virtio input handler, so the
        # events go to the current pointer handler, which is the tablet.
        return self.command("input-send-event", {"events": events})


class Machine:
    def __init__(self, devices, tag):
        self.dir = tempfile.mkdtemp(prefix=f"cassa-{tag}-")
        self.serial_path = os.path.join(self.dir, "serial.sock")
        self.monitor_path = os.path.join(self.dir, "monitor.sock")
        self.qmp_path = os.path.join(self.dir, "qmp.sock")
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = LIB
        command = [
            QEMU,
            "-machine", "virt",
            "-cpu", "cortex-a53",
            "-m", "512M",
            "-smp", "4",
            "-display", "none",
            "-serial", f"unix:{self.serial_path},server=on,wait=off",
            "-monitor", f"unix:{self.monitor_path},server=on,wait=off",
            "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
            "-nic", "none",
            "-global", "virtio-mmio.force-legacy=false",
            "-device", "bochs-display,romfile=,xres=1280,yres=800",
        ]
        if devices:
            command += [
                "-device", "virtio-keyboard-device,id=keyboard0",
                "-device", "virtio-tablet-device,id=tablet0",
            ]
        command += ["-no-reboot", "-kernel", KERNEL]
        log(f"[{tag}] starting qemu ({'with' if devices else 'without'} input devices)")
        self.proc = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        self.serial = Socket(self.serial_path)
        self.monitor = Socket(self.monitor_path)
        self.monitor.wait_for("(qemu)", 20)
        self.qmp = Qmp(self.qmp_path)
        self.boot = self.serial.wait_for("cassa> ", 90)
        log(f"[{tag}] booted to shell prompt")

    def shell(self, command, timeout=30):
        # The shell echoes every command. Waiting for that echo first keeps a
        # prompt left over from an asynchronous view (with no prompt of its own)
        # from being mistaken for this command's completion.
        self.serial.buffer = ""
        self.serial.send(command + "\r")
        self.serial.wait_for(command, timeout)
        return self.serial.wait_for("cassa> ", timeout)

    def key(self, *keys):
        for key in keys:
            self.monitor.send(f"sendkey {key}\n")
            self.monitor.wait_for("(qemu) ", 10)

    def mouse_move(self, dx, dy):
        self.monitor.send(f"mouse_move {dx} {dy}\n")
        self.monitor.wait_for("(qemu) ", 10)

    def mouse_button(self, button, down):
        state = "1" if down else "0"
        self.monitor.send(f"mouse_button {button} {state}\n")
        self.monitor.wait_for("(qemu) ", 10)

    def screendump(self, path):
        self.monitor.send(f"screendump {path}\n")
        self.monitor.wait_for("(qemu) ", 20)

    def stop(self):
        try:
            self.serial.send("halt\r")
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)


def run_with_devices():
    machine = Machine(True, "with-input")
    failures = []

    info = machine.shell("input")
    log(info)
    for expected in ("scanner", "QEMU Virtio Keyb", "QEMU Virtio Tabl", "keyboard", "tablet"):
        if expected not in info:
            failures.append(f"`input` output is missing {expected!r}")

    # --- live view, typed keys, pointer motion and a panel screenshot --------
    machine.serial.send("input viz 7\r")
    machine.serial.wait_for("viz         : 7s", 10)
    time.sleep(1.5)
    machine.key("h", "e", "l", "p")
    machine.qmp.pointer(9000, 6000, None)
    machine.qmp.pointer(18000, 12000, True)
    machine.qmp.pointer(18000, 12000, False)
    screenshot = os.path.join(machine.dir, "input-viz.ppm")
    machine.screendump(screenshot)
    log(f"panel screenshot: {screenshot}")
    viz = machine.serial.wait_for("viz         : closed", 25)
    log(viz)
    for expected in ("key", "pointer", "button"):
        if expected not in viz:
            failures.append(f"live view did not report a {expected} event")

    # --- barcode burst: 13 digits and Enter, all through the keyboard ------
    machine.shell("input gap 300")
    machine.shell("input minlen 4")
    reset = machine.shell("input reset")
    log(reset)
    empty = machine.shell("input dump 4")
    log(empty)
    if "queue empty" not in empty:
        failures.append("the event queue was not empty before the scan")

    machine.key(*list(BARCODE), "ret")
    machine.serial.wait_for("[scan]", 15)
    notice = machine.serial.wait_for(BARCODE, 15)
    notice += machine.serial.wait_for("burst)", 15)
    log(notice)

    info = machine.shell("input")
    log(info)
    if "1 committed" not in info:
        failures.append("scanner did not commit exactly one scan")
    delivery_line = next((line for line in info.splitlines() if "delivery" in line), "")
    log(f"delivery line: {delivery_line.strip()}")
    delivery = re.search(r"last (\d+) ms", delivery_line)
    if not delivery or int(delivery.group(1)) >= 20:
        failures.append("scan delivery to the event queue was not within the 20 ms budget")
    latency = None
    for line in info.splitlines():
        if "scan timing" in line:
            latency = line.strip()
    log(f"scanner timing line: {latency}")

    dump = machine.shell("input dump 8")
    log(dump)
    if BARCODE not in dump:
        failures.append("the barcode event is not in the kernel event queue")
    if "barcode" not in dump:
        failures.append("the queued event is not of kind barcode")

    # --- USB HID decoders through the same queue ---------------------------
    hid = machine.shell("hid")
    log(hid)
    if "HID path" not in hid or "PASS" not in hid:
        failures.append("HID decoder self-test did not pass")

    # --- key remapping -----------------------------------------------------
    remap = machine.shell("keymap map 30 31")
    log(remap)
    keymap = machine.shell("keymap info")
    log(keymap)
    if "30 (A) -> 31 (S)" not in keymap:
        failures.append("key remap was not recorded")
    machine.shell("keymap reset")

    # --- final panel state -------------------------------------------------
    final = os.path.join(machine.dir, "input-shell.ppm")
    machine.screendump(final)
    log(f"final screenshot: {final}")
    machine.stop()

    return machine, failures


def run_without_devices():
    machine = Machine(False, "no-input")
    failures = []
    info = machine.shell("input")
    log(info)
    if "QEMU Virtio" in info:
        failures.append("a machine without input devices still reports a virtio input device")
    selftest = machine.shell("selftest")
    log(selftest)
    if "PASS" not in selftest:
        failures.append("boot self-tests failed without input devices")
    machine.stop()
    return machine, failures


def main():
    if not os.path.exists(KERNEL):
        log(f"missing {KERNEL}: run `zig build` first")
        return 2

    overall = []
    with_machine, failures = run_with_devices()
    overall += [(with_machine, failures)]
    without_machine, failures = run_without_devices()
    overall += [(without_machine, failures)]

    print()
    ok = True
    for machine, failures in overall:
        if failures:
            ok = False
            log(f"FAIL {machine.dir}")
            for failure in failures:
                log(f"  - {failure}")
        else:
            log(f"PASS {machine.dir}")
    if ok:
        log("phase 38 input evidence: PASS")
        return 0
    log("phase 38 input evidence: FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
