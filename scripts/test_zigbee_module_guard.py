#!/usr/bin/env python3
"""Checks the decisions of package/zigbee_module_guard.py: no controller, module or systemd needed.

Usage: test_zigbee_module_guard.py [path to zigbee_module_guard.py]
Exit:  0 passed, 1 a check failed
"""

import importlib.util
import os
import pathlib
import sys
import tempfile

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


def test_configuration(guard, directory):
    """The slot found in a configuration; None: not a module to look after"""
    cases = (
        (
            "MOD3, and frontend has a port too",
            "serial:\n  port: /dev/ttyMOD3\n  adapter: zstack\nfrontend:\n  port: 1\n",
            3,
        ),
        (
            "CRLF, quotes and a comment",
            "serial:\r\n  port: '/dev/ttyMOD1'\r\n  adapter: \"zstack\"  # ours\r\n",
            1,
        ),
        ("a USB stick", "serial:\n  port: /dev/ttyUSB0\n  adapter: zstack\n", None),
        ("another adapter", "serial:\n  port: /dev/ttyMOD1\n  adapter: ember\n", None),
        ("no adapter named", "serial:\n  port: /dev/ttyMOD1\n", None),
        ("the port of the template, MOD0", "serial:\n  port: /dev/ttyMOD0\n  adapter: zstack\n", None),
        ("a network coordinator", "serial:\n  port: tcp://192.168.1.2:6638\n  adapter: zstack\n", None),
    )
    path = os.path.join(directory, "configuration.yaml")
    for name, text, expected in cases:
        with open(path, "w", encoding="utf-8", newline="") as config:
            config.write(text)
        check(f"configuration: {name}", expected, guard.module_slot(guard.read_serial_settings(path)))
    os.remove(path)
    check("configuration: no file", None, guard.module_slot(guard.read_serial_settings(path)))


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


def test_watch_decisions(guard, capture, directory):
    """watch_running with fake counters, sleep and systemctl"""
    restarts = []
    state = {}
    guard.STATE_PATH = os.path.join(directory, "state.json")
    guard.time.sleep = lambda _seconds: None
    guard.systemctl = lambda *arguments: restarts.append(arguments) if "restart" in arguments else None
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

    with open(guard.STATE_PATH, "w", encoding="utf-8") as broken:
        broken.write("[]")
    passes("a state file that holds no sample is a first look", "active", "400", [(0, 50)], 2)
    capture()


def test_port_error(guard, capture):
    """A slot whose UART is not set up: termios fails, and its error is not an OSError"""

    def broken_port(_port_path):
        raise guard.termios.error(5, "Input/output error")

    guard.read_serial_settings = lambda _path: {"port": "/dev/ttyMOD1", "adapter": "zstack"}
    guard.unit_properties = lambda: {"ActiveState": "activating"}
    guard.module_answers = broken_port
    guard.command_recover()
    logged = capture()
    check(
        "recover: a port that cannot be set up is one warning",
        True,
        len(logged) == 1 and "cannot check" in logged[0],
    )


def main():
    guard = load_guard(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_GUARD)
    lines = []
    guard.print = lambda text, **_: lines.append(text)

    def capture():
        taken = list(lines)
        lines.clear()
        return taken

    with tempfile.TemporaryDirectory() as directory:
        test_configuration(guard, directory)
        test_judge(guard)
        test_log(guard, capture)
        test_watch_decisions(guard, capture, directory)
        test_port_error(guard, capture)

    print(f"\n{len(FAILED)} failed" if FAILED else "\nall passed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
