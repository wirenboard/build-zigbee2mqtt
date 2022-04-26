#!/bin/sh -e

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

if [ -e "$CONFIG_FILE.wb-old" ]; then
    echo "Restoring config file after upgrade from old malformed zigbee2mqtt package version"
    mv $CONFIG_FILE.wb-old $CONFIG_FILE
fi
