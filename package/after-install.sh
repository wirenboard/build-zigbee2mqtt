#!/bin/sh
# Runs on the controller after a first install. fpm inlines it: README.md, "The maintainer scripts"

# The configuration is not a dpkg conffile and never travels in the package: README.md,
# "The configuration on the controller". Created here from the template when there is none
/usr/lib/zigbee2mqtt/setup-z2m-config.sh
