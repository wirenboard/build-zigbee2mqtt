#!/bin/sh
# Copies the data of zigbee2mqtt into /var/backups before dpkg installs or upgrades it: it shows
# that configuration.yaml can stop being a dpkg conffile without anyone losing data.
# TEMPORARY: after 2027-01 remove the backup step: this file and the fpm flags that inline it.
# fpm inlines it into a maintainer script function: nothing here may call exit, and return works
# only inside backup_z2m_data().

Z2M_DATA_PATH=/mnt/data/root/zigbee2mqtt/data
Z2M_BACKUP_PATH=/var/backups/zigbee2mqtt
# Three copies are enough: a user upgrades, something breaks, they upgrade once more, and only
# then look for a copy
Z2M_BACKUPS_TO_KEEP=3

# Every line goes into the apt log next to lines from other packages, so it starts with the
# package name. The function names start with backup_ because this file is inlined into a
# maintainer script shared with other code
backup_log() { echo "zigbee2mqtt: $*"; }
backup_warn() { echo "zigbee2mqtt: $*" >&2; }

# new_backup_path: a name of the form <date>T<time> that no copy occupies yet. Two runs inside
# one second would otherwise share a directory
new_backup_path() {
    local path attempt
    path="${Z2M_BACKUP_PATH}/$(date +%Y-%m-%dT%H-%M-%S)"
    attempt=1
    while [ -e "${path}" ] || [ -e "${path}.partial" ]; do
        path="${Z2M_BACKUP_PATH}/$(date +%Y-%m-%dT%H-%M-%S)-${attempt}"
        attempt=$((attempt + 1))
    done
    echo "${path}"
}

# copy_data_files <directory>: copies the files of the data directory, without "log", which is
# of no use in a copy. The form "-exec ... +" is required: with "-exec ... \;" find returns 0 even
# when cp failed. With "+" the target goes into "-t", because "{}" must be the last argument
copy_data_files() {
    mkdir -p "$1" &&
        find "${Z2M_DATA_PATH}" -maxdepth 1 -type f -exec cp -a -t "$1" {} +
}

# package_name: the name this package really has, with VERSION_TO_NAME it is zigbee2mqtt-1.18.1
package_name() { echo "${DPKG_MAINTSCRIPT_PACKAGE:-zigbee2mqtt}"; }

# old_version <package> <version passed by fpm>: empty when dpkg knows no package of that name
old_version() {
    if [ -n "$2" ]; then
        echo "$2"
    else
        dpkg-query -W -f='${Version}' "$1" 2>/dev/null
    fi
}

# dpkg_action <package> <old version>: what dpkg is about to do, as wb-backup-info.txt says it
dpkg_action() {
    if [ -z "$2" ]; then
        echo "install"
    elif dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q config-files; then
        echo "install after remove"
    else
        echo "upgrade"
    fi
}

# write_backup_info <directory> <package> <dpkg action> <old version>
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
        echo "put back: stop zigbee2mqtt, copy the files from this directory into the directory" \
             "above, start zigbee2mqtt"
    } > "$1/wb-backup-info.txt"
}

# remove_unfinished_copies: a copy interrupted by a power cut leaves a ".partial" behind, and
# nothing else ever removes it, while rotation counts it as a copy
remove_unfinished_copies() {
    local stale
    for stale in "${Z2M_BACKUP_PATH}"/*.partial; do
        [ -d "${stale}" ] || continue
        backup_log "removing the unfinished copy ${stale} of an earlier run"
        rm -rf "${stale}"
    done
}

# rotate_backups: keeps the Z2M_BACKUPS_TO_KEEP newest copies and removes the rest. "ls -t"
# sorts by time and not by name on purpose: a name with a suffix, "...-05-18-2", sorts before
# "...-05-18", so sorting by name would delete the newest copy
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

    remove_unfinished_copies
    backup_path=$(new_backup_path)
    partial_path="${backup_path}.partial"

    if ! copy_data_files "${partial_path}"; then
        backup_warn "could not copy ${Z2M_DATA_PATH} to ${partial_path}, removing it"
        rm -rf "${partial_path}"
        return 0
    fi

    name=$(package_name)
    version=$(old_version "${name}" "${1:-}")
    what=$(dpkg_action "${name}" "${version}")
    # The note is written and the directory is renamed in one condition: if the note did not fit
    # on the disk, the copy next to it cannot be trusted either
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
