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
        # fpm calls this from before_install without arguments, and from before_upgrade with the
        # version being replaced, so "$1" tells an install from an upgrade. dpkg-query is the
        # fallback, and it is asked about the name this package really has: with VERSION_TO_NAME
        # it is zigbee2mqtt-1.18.1 and not zigbee2mqtt
        package_name=${DPKG_MAINTSCRIPT_PACKAGE:-zigbee2mqtt}
        old_version=${1:-}
        [ -n "${old_version}" ] ||
            old_version=$(dpkg-query -W -f='${Version}' "${package_name}" 2>/dev/null)

        if [ -z "${old_version}" ]; then
            # Nothing of this name in the dpkg database, so the data came from somewhere else
            action="install"
            old_version="none"
        elif dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null | grep -q config-files; then
            # Removed but not purged: dpkg still keeps the version that was there
            action="install after remove"
        else
            # The same for a reinstall of the same version: dpkg does not tell a preinst the
            # version it is installing, so the two cannot be told apart here
            action="upgrade"
        fi

        # Plain words: this file is read on a controller, by a person in a hurry
        {
            echo "date: $(date +'%Y-%m-%d %H:%M:%S')"
            echo "action: ${action}"
            echo "package: ${package_name}"
            echo "old version: ${old_version}"
            echo "copy of: ${Z2M_DATA_PATH}"
            echo "put back: stop zigbee2mqtt, copy the files that lie next to this one into the" \
                 "directory above, start zigbee2mqtt"
        } > "${backup_path}/wb-backup-info.txt"
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
