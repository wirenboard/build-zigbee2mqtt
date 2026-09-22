#!/bin/sh
# TEMPORARY. Copies the data of zigbee2mqtt into /var/backups before an install or an upgrade.
# Why it is here and when it goes away: README.md, "Copy of the data before an install".
# fpm inlines it: README.md, "The maintainer scripts"

Z2M_DATA_PATH=/mnt/data/root/zigbee2mqtt/data
Z2M_BACKUP_PATH=/var/backups/zigbee2mqtt

if [ ! -d "${Z2M_DATA_PATH}" ]; then
    echo "zigbee2mqtt: no data of an earlier installation, nothing to copy"
else
    backup_path="${Z2M_BACKUP_PATH}/$(date +%Y-%m-%dT%H-%M-%S)"
    # Two runs inside one second would otherwise share a directory, and the older copy has to stay
    attempt=1
    while [ -e "${backup_path}" ]; do
        backup_path="${Z2M_BACKUP_PATH}/$(date +%Y-%m-%dT%H-%M-%S)-${attempt}"
        attempt=$((attempt + 1))
    done
    # Files only: "log" is in the same directory and is of no use in a copy
    if mkdir -p "${backup_path}" &&
       find "${Z2M_DATA_PATH}" -maxdepth 1 -type f -exec cp -a {} "${backup_path}/" \; ; then
        version_before=$(dpkg-query -W -f='${Version}' zigbee2mqtt 2>/dev/null)
        echo "installed version before this run: ${version_before:-none}" \
            > "${backup_path}/wb-backup-info.txt"
        echo "zigbee2mqtt: the data of this installation is copied to ${backup_path}"
    else
        echo "zigbee2mqtt: could not copy ${Z2M_DATA_PATH} to ${backup_path}" >&2
    fi
fi
