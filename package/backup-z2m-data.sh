#!/bin/sh
# Copies the data of zigbee2mqtt into /var/backups before dpkg installs or upgrades it: proof
# that the move of configuration.yaml off dpkg conffiles loses nothing on real controllers.
# TEMPORARY: after 2027-01 remove the backup step: this file and the fpm flags that inline it.
# fpm inlines it into a maintainer script function: no exit here, return only inside the function.

Z2M_DATA_PATH=/mnt/data/root/zigbee2mqtt/data
Z2M_BACKUP_PATH=/var/backups/zigbee2mqtt
# A user upgrades, something breaks, they try once more and only then start looking, so three
# copies are enough and anything older helps nobody
Z2M_BACKUPS_TO_KEEP=3

# The lines land in the apt log among everyone else's, so they name the writer. The names
# carry a prefix: this file is inlined into a maintainer script shared with other code
backup_log() { echo "zigbee2mqtt: $*"; }
backup_warn() { echo "zigbee2mqtt: $*" >&2; }

# free_backup_path: a name of the form <date>T<time> that no copy occupies yet. Two runs inside
# one second would otherwise share a directory
free_backup_path() {
    local path attempt
    path="${Z2M_BACKUP_PATH}/$(date +%Y-%m-%dT%H-%M-%S)"
    attempt=1
    while [ -e "${path}" ] || [ -e "${path}.partial" ]; do
        path="${Z2M_BACKUP_PATH}/$(date +%Y-%m-%dT%H-%M-%S)-${attempt}"
        attempt=$((attempt + 1))
    done
    echo "${path}"
}

# copy_data_files <directory>: the files of the data directory, "log" is of no use in a copy.
# "+" and not "\;": with ";" find returns 0 even when cp failed, and the target then goes
# into "-t", because "{}" has to be last
copy_data_files() {
    mkdir -p "$1" &&
        find "${Z2M_DATA_PATH}" -maxdepth 1 -type f -exec cp -a -t "$1" {} +
}

# package_name: the name this package really has, with VERSION_TO_NAME it is zigbee2mqtt-1.18.1
package_name() { echo "${DPKG_MAINTSCRIPT_PACKAGE:-zigbee2mqtt}"; }

# old_version <package> <version fpm passed>: empty when dpkg knows no package of that name
old_version() {
    if [ -n "$2" ]; then
        echo "$2"
    else
        dpkg-query -W -f='${Version}' "$1" 2>/dev/null
    fi
}

# made_before <package> <old version>: what dpkg is about to do, as wb-backup-info.txt says it
made_before() {
    if [ -z "$2" ]; then
        echo "install"
    elif dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q config-files; then
        echo "install after remove"
    else
        echo "upgrade"
    fi
}

# write_backup_info <directory> <package> <made before> <old version>
write_backup_info() {
    {
        echo "# Written automatically by the zigbee2mqtt package, before dpkg changed anything."
        echo "# For whoever is looking for a configuration that went missing."
        echo
        echo "backup time: $(date +'%Y-%m-%d %H:%M:%S %z (%Z)')"
        echo "made before dpkg action: $3"
        echo "package: $2"
        echo "old version: ${4:-none}"
        echo "copy of: ${Z2M_DATA_PATH}"
        echo "put back: stop zigbee2mqtt, copy the files that lie next to this one into the" \
             "directory above, start zigbee2mqtt"
    } > "$1/wb-backup-info.txt"
}

# remove_stale_partials: a copy interrupted by a power cut leaves a ".partial" behind, and
# nothing else ever removes it, while rotation counts it as a copy
remove_stale_partials() {
    local stale
    for stale in "${Z2M_BACKUP_PATH}"/*.partial; do
        [ -d "${stale}" ] || continue
        backup_log "removing the unfinished copy ${stale} of an earlier run"
        rm -rf "${stale}"
    done
}

# rotate_backups: keeps the Z2M_BACKUPS_TO_KEEP newest copies and removes the rest. "ls -t"
# sorts by time and not by name on purpose: a name with a suffix, "...-05-18-2", sorts before
# "...-05-18", so by name the newest copy would be the one to go
rotate_backups() {
    local older_copy
    # "tail -n +N" starts printing at line N, so the copies to keep are the lines before it
    ls -1dt "${Z2M_BACKUP_PATH}"/*/ 2>/dev/null | tail -n +$((Z2M_BACKUPS_TO_KEEP + 1)) |
        while read -r older_copy; do
            backup_log "removing the older copy ${older_copy}"
            rm -rf "${older_copy}"
        done
}

backup_z2m_data() {
    local backup_path partial_path name version what
    if [ ! -d "${Z2M_DATA_PATH}" ]; then
        backup_log "no data of an earlier installation, nothing to copy"
        return 0
    fi

    remove_stale_partials
    backup_path=$(free_backup_path)
    partial_path="${backup_path}.partial"

    if ! copy_data_files "${partial_path}"; then
        backup_warn "could not copy ${Z2M_DATA_PATH} to ${partial_path}, removing it"
        rm -rf "${partial_path}"
        return 0
    fi

    name=$(package_name)
    version=$(old_version "${name}" "${1:-}")
    what=$(made_before "${name}" "${version}")
    # The note and the rename are one condition: a note that did not fit on the disk means the
    # copy next to it is not to be trusted either
    if write_backup_info "${partial_path}" "${name}" "${what}" "${version}" &&
       mv "${partial_path}" "${backup_path}"
    then
        backup_log "the data of this installation is copied to ${backup_path}"
        rotate_backups
    else
        backup_warn "could not finish the copy ${partial_path}, removing it"
        rm -rf "${partial_path}"
    fi
    return 0
}

backup_z2m_data "$@"
