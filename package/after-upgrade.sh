#!/bin/sh -e

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

echo "Adding dependencies for pnpm"
pnpm install --frozen-lockfile --prefix /mnt/data/root/zigbee2mqtt

if [ -e "$CONFIG_FILE.wb-old" ]; then
    echo "Restoring config file after upgrade from old malformed zigbee2mqtt package version"
    mv $CONFIG_FILE.wb-old $CONFIG_FILE
fi
