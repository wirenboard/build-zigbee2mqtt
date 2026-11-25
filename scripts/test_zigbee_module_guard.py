#!/usr/bin/env python3
"""Checks package/zigbee_module_guard.py without a controller: a pseudo-terminal plays the module.

Usage: test_zigbee_module_guard.py [path to zigbee_module_guard.py]
Exit:  0 passed, 1 a check failed, 77 no pseudo-terminal here
"""

import importlib.util
import os
import pathlib
import pty
import sys
import tempfile
import threading
import time

DEFAULT_GUARD = pathlib.Path(__file__).resolve().parent.parent / "package" / "zigbee_module_guard.py"

FAILED = []


def check(what, expected, actual):
    verdict = "ok   " if expected == actual else "FAIL "
    print(f"{verdict} {what}" + ("" if expected == actual else f": expected {expected!r}, got {actual!r}"))
    if expected != actual:
        FAILED.append(what)


def load_guard(path):
    spec = importlib.util.spec_from_file_location("guard", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeModule:
    """The other end of a pseudo-terminal, answers by a table"""

    def __init__(self, answers):
        self.answers = answers
        self.master, slave = pty.openpty()
        self.path = os.ttyname(slave)
        self.slave = slave
        self.received = b""
        self.running = True
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while self.running:
            try:
                data = os.read(self.master, 256)
            except OSError:
                return
            self.received += data
            for request, answer in self.answers.items():
                if self.received.endswith(request):
                    os.write(self.master, answer)

    def close(self):
        self.running = False
        os.close(self.slave)
        os.close(self.master)


def write_config(text):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, newline="") as config:
        config.write(text)
        return config.name


def test_configuration(guard):
    path = write_config(
        "mqtt:\n  server: 'mqtt+unix:///var/run/mosquitto/mosquitto.sock'\n"
        "serial:\n  port: /dev/ttyMOD3\n  adapter: zstack\n"
        "frontend:\n  port: 8081\n"
    )
    settings = guard.read_serial_settings(path)
    check("the port is read from the serial block, not from frontend", "/dev/ttyMOD3", settings.get("port"))
    check("a zstack module in MOD3 is slot 3", 3, guard.module_slot(settings))

    crlf = write_config("serial:\r\n  port: '/dev/ttyMOD1'\r\n  adapter: \"zstack\"  # ours\r\n")
    check(
        "CRLF, quotes and a comment do not hide the slot",
        1,
        guard.module_slot(guard.read_serial_settings(crlf)),
    )

    for name, text in (
        ("a USB stick", "serial:\n  port: /dev/ttyUSB0\n  adapter: zstack\n"),
        ("another adapter", "serial:\n  port: /dev/ttyMOD1\n  adapter: ember\n"),
        ("no adapter named", "serial:\n  port: /dev/ttyMOD1\n"),
        ("the port of the template, MOD0", "serial:\n  port: /dev/ttyMOD0\n  adapter: zstack\n"),
        ("a network coordinator", "serial:\n  port: tcp://192.168.1.2:6638\n  adapter: zstack\n"),
    ):
        check(
            f"{name} is not a module to look after",
            None,
            guard.module_slot(guard.read_serial_settings(write_config(text))),
        )
    check(
        "a missing configuration is not a module to look after",
        None,
        guard.module_slot(guard.read_serial_settings("/nonexistent")),
    )


def test_judge(guard):
    base = {"since": "100", "rx": 5000, "tx": 3000}
    cases = (
        ("no earlier look", None, base, "first"),
        ("zigbee2mqtt restarted in between", {**base, "since": "50"}, base, "first"),
        ("the counters started over", {**base, "rx": 9000}, base, "first"),
        ("the module sent something", base, {**base, "rx": 5001, "tx": 3000}, "talking"),
        ("both sides sent", base, {**base, "rx": 5200, "tx": 3100}, "talking"),
        ("a quiet network, nobody sent anything", base, dict(base), "idle"),
        ("requests went out and nothing came back", base, {**base, "tx": 3020}, "silent"),
    )
    for name, previous, current, expected in cases:
        check(f"judge: {name}", expected, guard.judge(previous, current))


def test_ping(guard):
    healthy = FakeModule({guard.SYS_PING_REQUEST: guard.SYS_PING_RESPONSE + b"\x59\x00\x3b"})
    started = time.monotonic()
    check("a module that answers SYS ping", True, guard.module_answers(healthy.path, timeout=1))
    check(
        "the answer of a healthy module does not wait for the timeout", True, time.monotonic() - started < 0.5
    )
    healthy.close()

    silent = FakeModule({})
    check("a silent module", False, guard.module_answers(silent.path, attempts=2, timeout=0.3))
    check(
        "a silent module was asked twice, the second time after the skip-bootloader byte",
        guard.SYS_PING_REQUEST + guard.SKIP_BOOTLOADER_BYTE + guard.SYS_PING_REQUEST,
        silent.received,
    )
    silent.close()

    noisy = FakeModule({guard.SYS_PING_REQUEST: b"\x00\x00\xfe\x02\x61"})
    check("a cut answer is not an answer", False, guard.module_answers(noisy.path, attempts=1, timeout=0.3))
    noisy.close()


def test_bootloader(guard):
    bootloader = FakeModule(
        {guard.BOOTLOADER_SYNC: guard.BOOTLOADER_ACK, guard.BOOTLOADER_RESET: guard.BOOTLOADER_ACK}
    )
    check(
        "the bootloader acknowledges and is told to start the firmware",
        True,
        guard.leave_bootloader(bootloader.path, timeout=1),
    )
    check("what the bootloader was sent", guard.BOOTLOADER_SYNC + guard.BOOTLOADER_RESET, bootloader.received)
    bootloader.close()

    absent = FakeModule({})
    check("no bootloader on the line", False, guard.leave_bootloader(absent.path, timeout=0.3))
    absent.close()


def test_log(guard, capture):
    os.environ["JOURNAL_STREAM"] = "8:12345"
    guard.log("warning", "x")
    guard.log("notice", "x")
    guard.log("debug", "x")
    del os.environ["JOURNAL_STREAM"]
    guard.log("warning", "y")
    check(
        "journal priorities and the plain form",
        ["<4>zigbee2mqtt: x", "<5>zigbee2mqtt: x", "<7>zigbee2mqtt: x", "zigbee2mqtt: warning: y"],
        capture(),
    )


def test_watch_decisions(guard, capture):
    """watch_running with fake counters, sleep and systemctl"""
    restarts = []
    state = {}
    guard.STATE_PATH = tempfile.mktemp()
    guard.time.sleep = lambda _seconds: None
    guard.run = lambda command: restarts.append(command) if "restart" in command else None
    guard.unit_properties = lambda: {
        "ActiveState": state["unit"],
        "ActiveEnterTimestampMonotonic": state["since"],
    }
    guard.read_counters = lambda _port: state["counters"].pop(0)

    def passes(name, unit, since, counters, expected_restarts):
        state.update(unit=unit, since=since, counters=list(counters))
        guard.watch_running("/dev/ttyMOD1", guard.unit_properties())
        check(f"watch: {name}", expected_restarts, len(restarts))

    passes("the first look restarts nothing", "active", "100", [(1000, 500)], 0)
    passes("a talking module", "active", "100", [(1900, 800)], 0)
    passes("a quiet network", "active", "100", [(1900, 800)], 0)
    passes("silent at first, answered while waiting", "active", "100", [(1900, 830), (1950, 830)], 0)
    passes("the same look again after that", "active", "100", [(1950, 830)], 0)
    passes("silent and still silent after the wait", "active", "100", [(1950, 890), (1950, 950)], 1)
    passes("the look after the restart is a first one", "active", "200", [(10, 30)], 1)
    passes("silent since the restart: requests and no bytes", "active", "200", [(10, 60), (10, 90)], 2)

    state.update(unit="active", since="300", counters=[(0, 0)])
    guard.watch_running("/dev/ttyMOD1", guard.unit_properties())
    state.update(unit="inactive", since="300", counters=[(0, 40)])
    guard.watch_running("/dev/ttyMOD1", {"ActiveState": "active", "ActiveEnterTimestampMonotonic": "300"})
    check("watch: zigbee2mqtt stopped while waiting, nothing is restarted", 2, len(restarts))
    capture()


def main():
    try:
        os.close(pty.openpty()[0])
    except OSError as error:
        print(f"no pseudo-terminal here, nothing checked: {error}")
        return 77
    guard = load_guard(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_GUARD)
    lines = []
    guard.print = lambda text, **_: lines.append(text)

    def capture():
        taken = list(lines)
        lines.clear()
        return taken

    test_configuration(guard)
    test_judge(guard)
    test_ping(guard)
    test_bootloader(guard)
    test_log(guard, capture)
    test_watch_decisions(guard, capture)

    print(f"\n{len(FAILED)} failed" if FAILED else "\nall passed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
