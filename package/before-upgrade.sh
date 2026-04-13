#!/bin/sh

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

# Always backup configuration before upgrade to preserve user settings
# (network_key, pan_id, devices, etc.)
if [ -e "$CONFIG_FILE" ]; then
    echo "Saving configuration file before upgrade"
    cp "$CONFIG_FILE" "$CONFIG_FILE.wb-upgrade-backup"
fi

if ! command -v pnpm &> /dev/null; then
    echo "pnpm is not installed. Install via corepack..."
    corepack enable pnpm
fi
