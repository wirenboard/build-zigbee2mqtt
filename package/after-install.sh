#!/bin/sh
# Runs on the controller after a first install. fpm inlines it into a maintainer script function,
# where a failing command does not stop the install

# The configuration never travels in the package, it is created here from the template
/usr/lib/zigbee2mqtt/setup-z2m-config.sh

# The watchdog timer is a plain file for fpm, see scripts/build.sh, so it is enabled here
systemctl --system daemon-reload > /dev/null 2>&1 || true
systemctl enable --now zigbee2mqtt-watchdog.timer > /dev/null 2>&1 || true
