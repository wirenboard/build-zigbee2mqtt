#!/bin/sh
# Runs on the controller after a first install. fpm inlines it into a maintainer script function,
# where a failing command does not stop the install

# The configuration never travels in the package, it is created here from the template
/usr/lib/zigbee2mqtt/setup-z2m-config.sh
