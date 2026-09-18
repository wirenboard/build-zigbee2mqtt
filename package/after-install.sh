#!/bin/sh
# Runs on the controller after a first install of the package.
# fpm inlines this file into the body of a function of the generated maintainer script, so the
# shebang and any `set` here would have no effect, and a failing command does not stop the install.
# That is why every step below reports for itself.

# The configuration is not a dpkg conffile: zigbee2mqtt rewrites it itself and keeps the network
# key and the paired devices there, so the package never ships it and never replaces it. It is
# created here from the template when the controller does not have one yet.
/usr/lib/zigbee2mqtt/setup-z2m-config.sh
