#!/bin/sh

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

# configuration.yaml was previously marked as dpkg conffile, but on upgrade
# dpkg prompts the user to replace or keep the modified config. Users often
# press Y (replace) accidentally, which overwrites network_key, pan_id and
# paired devices — effectively destroying the zigbee network.
# So we removed the conffile mark and handle backup/restore ourselves.
if [ -e "$CONFIG_FILE" ]; then
    echo "Saving configuration file before upgrade"
    cp "$CONFIG_FILE" "$CONFIG_FILE.wb-old"
fi

if ! command -v pnpm &> /dev/null; then
    echo "pnpm is not installed. Install via corepack..."
    corepack enable pnpm
fi
