#!/bin/sh
# Runs on the controller before an upgrade unpacks the new package.
# fpm inlines this file into the body of a function of the generated maintainer script, so the
# shebang and any `set` here would have no effect, and a failing command does not stop the upgrade.
# That is why every step below reports for itself.

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

# configuration.yaml is marked as dpkg conffile, so on upgrade dpkg may
# prompt the user to replace or keep the modified config. If the user
# presses Y (replace), it would overwrite network_key, pan_id and paired
# devices — effectively destroying the zigbee network.
# As a safety net, we always backup the config and restore it after upgrade.
if [ -e "${CONFIG_FILE}" ]; then
    echo "Saving configuration file before upgrade"
    if ! cp "${CONFIG_FILE}" "${CONFIG_FILE}.wb-old"; then
        echo "Failed to back up ${CONFIG_FILE} — aborting upgrade" >&2
        exit 1
    fi
fi

if ! command -v pnpm > /dev/null 2>&1; then
    echo "pnpm is not installed. Install via corepack..."
    corepack enable pnpm
fi
