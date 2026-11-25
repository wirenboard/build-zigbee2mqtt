#!/usr/bin/env python3
"""Resets a Zigbee module that has stopped answering zigbee2mqtt.

The Z-Stack firmware of the module hangs once in a few weeks and has no watchdog; zigbee2mqtt
does not notice. Only for the "zstack" adapter on /dev/ttyMOD1..4.

Usage: zigbee_module_guard.py recover   before the service starts: reset the module if it is silent
       zigbee_module_guard.py watch     timer pass: restart the service if the module went silent
Exit:  0 always, 2 usage
Log:   warning what went wrong, notice what was done, debug the rest
"""

import fcntl
import json
import os
import re
import select
import struct
import subprocess
import sys
import termios
import time

CONFIG_PATH = "/mnt/data/root/zigbee2mqtt/data/configuration.yaml"
STATE_PATH = "/run/zigbee2mqtt-module-guard.json"
UNIT = "zigbee2mqtt.service"

# The numbers come from the code they have to agree with, see README
BAUD = termios.B115200  # zigbee-herdsman default for zstack
ANSWER_TIMEOUT_S = 6  # zigbee-herdsman znp.ts, timeouts.SREQ
LONGEST_ANSWER_S = 40  # znp.ts, the requests that start the network
PING_ATTEMPTS = 3  # zigbee-herdsman zStackAdapter.ts, start()
SKIP_BOOTLOADER_WAIT_S = 1  # znp.ts, skipBootloader()
RTS_PULSE = "1000ms"  # wb-cc2652p-flasher
BOOTLOADER_ACK_TIMEOUT_S = 2  # cc2538-bsl serial timeout

SKIP_BOOTLOADER_BYTE = b"\xef"
SYS_PING_REQUEST = b"\xfe\x00\x21\x01\x20"
SYS_PING_RESPONSE = b"\xfe\x02\x61\x01"
BOOTLOADER_SYNC = b"\x55\x55"
BOOTLOADER_ACK = b"\x00\xcc"
BOOTLOADER_RESET = b"\x03\x25\x25"  # COMMAND_RESET of the CC26xx ROM bootloader

TIOCGICOUNT = 0x545D  # asm-generic/ioctls.h
ICOUNTER_FORMAT = "20i"  # struct serial_icounter_struct, rx and tx are fields 4 and 5

JOURNAL_PRIORITIES = {"warning": 4, "notice": 5, "info": 6, "debug": 7}


def log(level, text):
    """The journal takes the level as a "<N>" prefix"""
    if os.environ.get("JOURNAL_STREAM"):
        print(f"<{JOURNAL_PRIORITIES[level]}>zigbee2mqtt: {text}", flush=True)
    else:
        print(f"zigbee2mqtt: {level}: {text}", flush=True)


### the configuration of zigbee2mqtt


def read_serial_settings(path):
    """Keys of the top-level "serial:" block only"""
    settings = {}
    in_serial = False
    try:
        with open(path, encoding="utf-8", errors="replace") as config:
            for line in config:
                line = line.rstrip("\r\n")
                if line[:1] not in ("", " ", "\t", "#"):
                    in_serial = line.split("#")[0].strip() == "serial:"
                    continue
                match = re.match(r"\s+([A-Za-z_]+):\s*(.*?)\s*$", line)
                if in_serial and match:
                    settings[match.group(1)] = match.group(2).split(" #")[0].strip("'\" ")
    except OSError:
        pass
    return settings


def module_slot(settings):
    """Slot number of a module this script can reset, else None"""
    match = re.fullmatch(r"/dev/ttyMOD([1-4])", settings.get("port", ""))
    if settings.get("adapter") != "zstack" or not match:
        return None
    return int(match.group(1))


### the serial port


class SerialPort:
    """The port in raw mode at the speed of zigbee2mqtt, restored on exit"""

    def __init__(self, path):
        self.path = path
        self.fd = -1
        self.saved = None

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.saved = termios.tcgetattr(self.fd)
        raw = termios.tcgetattr(self.fd)
        raw[0] = raw[1] = raw[3] = 0
        raw[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        raw[4] = raw[5] = BAUD
        raw[6][termios.VMIN] = raw[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, raw)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        return self

    def __exit__(self, *_):
        try:
            termios.tcsetattr(self.fd, termios.TCSANOW, self.saved)
        except termios.error:
            pass
        os.close(self.fd)

    def write(self, data):
        os.write(self.fd, data)

    def read_until(self, expected, timeout):
        """True once the bytes arrive, False after the timeout"""
        received = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if not ready:
                continue
            try:
                received += os.read(self.fd, 4096)
            except BlockingIOError:
                continue
            if expected in received:
                return True
        return False


def module_answers(port_path, attempts=PING_ATTEMPTS, timeout=ANSWER_TIMEOUT_S):
    """Sends "SYS ping" the way zigbee2mqtt does on start"""
    with SerialPort(port_path) as port:
        for attempt in range(attempts):
            if attempt:
                port.write(SKIP_BOOTLOADER_BYTE)
                port.read_until(SYS_PING_RESPONSE, SKIP_BOOTLOADER_WAIT_S)
            port.write(SYS_PING_REQUEST)
            if port.read_until(SYS_PING_RESPONSE, timeout):
                return True
    return False


def leave_bootloader(port_path, timeout=BOOTLOADER_ACK_TIMEOUT_S):
    """Tells the ROM bootloader to start the firmware; False if it does not answer"""
    with SerialPort(port_path) as port:
        port.write(BOOTLOADER_SYNC)
        if not port.read_until(BOOTLOADER_ACK, timeout):
            return False
        port.write(BOOTLOADER_RESET)
        return port.read_until(BOOTLOADER_ACK, timeout)


def read_counters(port_path):
    """Bytes received and sent by the port since boot. Reads nothing, safe while the port is in use"""
    fd = os.open(port_path, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        raw = fcntl.ioctl(fd, TIOCGICOUNT, bytes(struct.calcsize(ICOUNTER_FORMAT)))
    finally:
        os.close(fd)
    counters = struct.unpack(ICOUNTER_FORMAT, raw)
    return counters[4], counters[5]


### the reset line of the slot


def run(command):
    return subprocess.run(command, capture_output=True, text=True, check=False)


def find_rts_line(slot):
    """(chip, line) named "MOD<slot> RTS", or None. Needs gpiod 2"""
    try:
        found = run(["gpioinfo", f"MOD{slot} RTS"])
    except OSError:
        return None
    fields = found.stdout.split()
    if found.returncode != 0 or len(fields) < 2 or not fields[1].isdigit():
        return None
    return fields[0], fields[1]


def pulse_rts(chip, line):
    """High, low, then back to an input as after boot"""
    for value in ("1", "0"):
        run(["gpioset", "-p", RTS_PULSE, "-t0", "-c", chip, f"{line}={value}"])
    run(["gpioget", "-c", chip, line])


### recover: before zigbee2mqtt starts


def recover(port_path, slot):
    """Returns (the module answers, it was reset)"""
    if module_answers(port_path):
        log("debug", f"the Zigbee module on {port_path} answers")
        return True, False

    log(
        "warning",
        f"the Zigbee module on {port_path} does not answer ({PING_ATTEMPTS} requests, "
        f"{ANSWER_TIMEOUT_S} s each): resetting it with the RTS line of slot {slot}",
    )
    rts = find_rts_line(slot)
    if rts is None:
        log("warning", f'no gpio line named "MOD{slot} RTS" (gpiod 2 finds it), the module is not reset')
        return False, False

    pulse_rts(*rts)
    log("debug", f"pulsed {rts[0]} line {rts[1]}, asking the bootloader to start the firmware")
    if not leave_bootloader(port_path):
        log("warning", f"the bootloader of the module on {port_path} did not answer after the reset pulse")
    time.sleep(SKIP_BOOTLOADER_WAIT_S)

    if module_answers(port_path):
        log("notice", f"the Zigbee module on {port_path} was reset and answers again")
        return True, True
    log("warning", f"the Zigbee module on {port_path} still does not answer after the reset")
    return False, True


def command_recover():
    slot = module_slot(read_serial_settings(CONFIG_PATH))
    if slot is None:
        log("debug", "serial.adapter is not zstack on /dev/ttyMOD1..4, no module to look after")
        return
    port_path = f"/dev/ttyMOD{slot}"
    if unit_properties().get("ActiveState") == "active":
        log("debug", f"zigbee2mqtt is running and {port_path} is its, the module is not touched")
        return
    try:
        recover(port_path, slot)
    except OSError as error:
        log("warning", f"cannot check the Zigbee module on {port_path}: {error}")


### watch: one pass of the timer


def unit_properties():
    shown = run(["systemctl", "show", UNIT, "-p", "ActiveState,UnitFileState,ActiveEnterTimestampMonotonic"])
    return dict(line.split("=", 1) for line in shown.stdout.splitlines() if "=" in line)


def load_sample():
    try:
        with open(STATE_PATH, encoding="utf-8") as state:
            return json.load(state)
    except (OSError, ValueError):
        return None


def save_sample(sample):
    with open(STATE_PATH, "w", encoding="utf-8") as state:
        json.dump(sample, state)


def forget_sample():
    try:
        os.remove(STATE_PATH)
    except OSError:
        pass


def judge(previous, current):
    """Compares two looks at the byte counters of the port.

    "first":   nothing to compare with: no earlier look, a restart in between, counters reset
    "talking": the module sent something
    "idle":    nobody sent anything
    "silent":  zigbee2mqtt sent requests and not a byte came back
    """
    if previous is None or previous.get("since") != current["since"]:
        return "first"
    received = current["rx"] - previous.get("rx", 0)
    sent = current["tx"] - previous.get("tx", 0)
    if received < 0 or sent < 0:
        return "first"
    if received > 0:
        return "talking"
    return "silent" if sent > 0 else "idle"


def take_sample(port_path, properties):
    received, sent = read_counters(port_path)
    return {"since": properties.get("ActiveEnterTimestampMonotonic"), "rx": received, "tx": sent}


def watch_running(port_path, properties):
    previous = load_sample()
    current = take_sample(port_path, properties)
    verdict = judge(previous, current)
    if verdict != "silent":
        save_sample(current)
        log("debug", f"the Zigbee module on {port_path}: {verdict}, counters {current['rx']}/{current['tx']}")
        return

    # A request sent a moment ago may still be answered
    log("debug", f"the Zigbee module on {port_path} is silent, looking again in {LONGEST_ANSWER_S} s")
    time.sleep(LONGEST_ANSWER_S)
    properties = unit_properties()
    if properties.get("ActiveState") != "active":
        forget_sample()
        return
    current = take_sample(port_path, properties)
    if judge(previous, current) != "silent":
        save_sample(current)
        log("debug", f"the Zigbee module on {port_path} answered meanwhile")
        return

    forget_sample()
    log(
        "warning",
        f"the Zigbee module on {port_path} has not sent a byte while zigbee2mqtt sent "
        f"{current['tx'] - previous['tx']}, and {LONGEST_ANSWER_S} s more changed nothing: "
        "restarting zigbee2mqtt, the module is checked and reset on its start",
    )
    run(["systemctl", "--no-block", "restart", UNIT])


def watch_failed(port_path, slot, properties):
    """The service gave up starting: retry only if the module was silent and the reset helped"""
    forget_sample()
    if properties.get("UnitFileState") != "enabled":
        log("debug", "zigbee2mqtt has failed and is not enabled, left alone")
        return
    answers, was_reset = recover(port_path, slot)
    if answers and was_reset:
        log("notice", "starting zigbee2mqtt, which had failed while the module was silent")
        run(["systemctl", "reset-failed", UNIT])
        run(["systemctl", "--no-block", "start", UNIT])
    elif answers:
        log("debug", "zigbee2mqtt has failed although the module answers, not a case for this watchdog")


def command_watch():
    slot = module_slot(read_serial_settings(CONFIG_PATH))
    if slot is None:
        forget_sample()
        log("debug", "serial.adapter is not zstack on /dev/ttyMOD1..4, no module to look after")
        return
    port_path = f"/dev/ttyMOD{slot}"
    properties = unit_properties()
    state = properties.get("ActiveState")
    try:
        if state == "active":
            watch_running(port_path, properties)
        elif state == "failed":
            watch_failed(port_path, slot, properties)
        else:
            forget_sample()
            log("debug", f"zigbee2mqtt is {state}, nothing to watch")
    except OSError as error:
        log("warning", f"cannot watch the Zigbee module on {port_path}: {error}")


def main(arguments):
    commands = {"recover": command_recover, "watch": command_watch}
    if len(arguments) != 2 or arguments[1] not in commands:
        print(__doc__, file=sys.stderr)
        return 2
    commands[arguments[1]]()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
