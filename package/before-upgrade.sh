#!/bin/sh
# Runs on the controller before an upgrade unpacks the new package. fpm inlines it into a
# maintainer script function, where a failing command does not stop the upgrade

# Stop the service while the files of the running version are still on the disk: stopped after
# the unpack, it logs "Failed to stop Zigbee2MQTT ... ENOENT" and does not write
# coordinator_backup.json. The script that runs after the unpack starts it again
Z2M_UNIT=zigbee2mqtt.service
if systemctl is-active --quiet "${Z2M_UNIT}" 2>/dev/null; then
    echo "zigbee2mqtt: stopping the service before its files are replaced"
    z2m_systemctl=$(command -v deb-systemd-invoke || echo systemctl)
    ${z2m_systemctl} stop "${Z2M_UNIT}" > /dev/null ||
        echo "zigbee2mqtt: warning: could not stop the service, the upgrade continues" >&2
fi

# The configuration is no longer a dpkg conffile and no longer travels inside the package, so
# there is nothing to save here: dpkg has no reason to touch "data/configuration.yaml" at all.

