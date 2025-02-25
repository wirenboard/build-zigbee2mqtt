#!/bin/sh

# In older zigbee2mqtt package builds data/configuration.yaml file
# is not marked as conffile so it is not preserved during upgrade.
# This script saves old configuration during upgrade from this
# malformed version.

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

if ! dpkg-query --showformat='\${Conffiles}' --show 'zigbee2mqtt*' | grep configuration.yaml >/dev/null; then
    echo "Saving modified config file from old malformed zigbee2mqtt package"
    mv $CONFIG_FILE $CONFIG_FILE.wb-old
fi

if ! command -v pnpm &> /dev/null; then
    echo "pnpm is not installed. Install via corepack..."
    corepack enable pnpm
fi
