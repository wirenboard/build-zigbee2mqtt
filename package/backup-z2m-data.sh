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
        # Three newest copies are kept: a user upgrades, something breaks, they try once more and
        # only then start looking. Anything older helps nobody, and /var is on the root filesystem.
        # By time and not by name: within one second the names carry a suffix, and "...-05-18-2"
        # sorts before "...-05-18", so the newest copy would be the one to go
        ls -1dt "${Z2M_BACKUP_PATH}"/*/ 2>/dev/null | tail -n +4 |
            while read -r older_copy; do
                echo "zigbee2mqtt: removing the older copy ${older_copy}"
                rm -rf "${older_copy}"
            done
    else
        echo "zigbee2mqtt: could not copy ${Z2M_DATA_PATH} to ${backup_path}" >&2
    fi
fi
