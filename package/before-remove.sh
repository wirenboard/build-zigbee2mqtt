#!/bin/sh
# Runs on the controller before the package is removed, not on an upgrade

# The watchdog timer is a plain file for fpm, see scripts/build.sh, so it is disabled here
systemctl disable --now zigbee2mqtt-watchdog.timer > /dev/null 2>&1 || true
rm -f /run/zigbee2mqtt-module-guard.json
