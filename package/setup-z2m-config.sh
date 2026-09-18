#!/bin/sh
# Creates the zigbee2mqtt configuration from the template when the controller has none, and fills
# in the serial port from the slot picked in the web interface. Details are in the README.
# Usage: setup-z2m-config.sh
# Exit:  always 0, neither the maintainer scripts nor the service may fail because of it
set -u

Z2M_CONFIG_PATH=/mnt/data/root/zigbee2mqtt/data/configuration.yaml
Z2M_CONFIG_TEMPLATE_PATH=/usr/share/zigbee2mqtt/configuration.default.yaml
WB_HARDWARE_CONFIG_PATH=/etc/wb-hardware.conf
ZIGBEE_MODULE_NAME=wbe2r-r-zigbee

# The lines land in the apt log and in the journal among everyone else's, so they name the writer
log() { echo "zigbee2mqtt: $*"; }

### the configuration file

create_z2m_config_if_missing() {
    [ -e "${Z2M_CONFIG_PATH}" ] && return 0
    [ -e "${Z2M_CONFIG_TEMPLATE_PATH}" ] || {
        log "no ${Z2M_CONFIG_TEMPLATE_PATH}, cannot create the configuration"
        return 0
    }

    if mkdir -p "$(dirname "${Z2M_CONFIG_PATH}")" &&
       cp "${Z2M_CONFIG_TEMPLATE_PATH}" "${Z2M_CONFIG_PATH}"
    then
        log "created ${Z2M_CONFIG_PATH} from the template"
    else
        log "could not create ${Z2M_CONFIG_PATH} from the template"
    fi
}

# read_port_from_file <path>: the port out of the serial: block, and out of that block only,
# because a configuration may well carry a frontend: port too. Earlier packages wrote the file
# with CRLF, hence the sub()
read_port_from_file() {
    awk '
        /^[^[:space:]#]/           { in_serial = ($0 ~ /^serial:/) }
        in_serial && $1 == "port:" { sub(/\r$/, "", $2); print $2; exit }
    ' "$1" 2>/dev/null
}

# write_port_to_file <path> <port>: replaces the port in the serial: block, keeping the indentation
write_port_to_file() {
    config_path=$1
    new_path="${config_path}.wb-new"
    if awk -v port="$2" '
           /^[^[:space:]#]/           { in_serial = ($0 ~ /^serial:/) }
           in_serial && $1 == "port:" && !written { sub(/port:.*/, "port: " port); written = 1 }
                                      { print }
       ' "${config_path}" > "${new_path}"
    then
        mv "${new_path}" "${config_path}"
    else
        rm -f "${new_path}"
        return 1
    fi
}

### the slot picked in the web interface

# Numbers of the slots the user has declared a Zigbee module in, one per line: "3" means the
# module sits in MOD3 and the adapter is therefore /dev/ttyMOD3
get_slots_with_zigbee_module() {
    [ -e "${WB_HARDWARE_CONFIG_PATH}" ] || return 0
    command -v jq > /dev/null 2>&1 || return 0
    jq -r --arg module "${ZIGBEE_MODULE_NAME}" \
       'to_entries[] | select(.value.module? == $module) | .key' \
       "${WB_HARDWARE_CONFIG_PATH}" 2>/dev/null |
        sed -n 's/.*mod\([0-9][0-9]*\)$/\1/p'
}

# set_port_in_z2m_config <port>: writes the port into the zigbee2mqtt configuration unless it
# already names another one. A port that differs from the one in the template counts as chosen
# by a human, quoted values included
set_port_in_z2m_config() {
    port=$1
    current_port=$(read_port_from_file "${Z2M_CONFIG_PATH}")
    [ "${current_port}" = "${port}" ] && return 0

    template_port=$(read_port_from_file "${Z2M_CONFIG_TEMPLATE_PATH}")
    if [ -n "${current_port}" ] && [ "${current_port}" != "${template_port}" ]; then
        log "serial.port is ${current_port} and not the ${port} of the selected slot;" \
            "leaving the configured port alone"
        return 0
    fi

    write_port_to_file "${Z2M_CONFIG_PATH}" "${port}" &&
        log "serial.port set to ${port}, the slot picked in the settings"
}

main() {
    create_z2m_config_if_missing
    [ -e "${Z2M_CONFIG_PATH}" ] || exit 0

    slots=$(get_slots_with_zigbee_module)
    # grep prints 0 when it matches nothing, so the count is right even for an empty list
    case "$(printf '%s\n' "${slots}" | grep -c '[0-9]')" in
        0) log "no Zigbee module is selected in the controller settings; pick the slot there," \
               "or set serial.port in ${Z2M_CONFIG_PATH} by hand" ;;
        1) set_port_in_z2m_config "/dev/ttyMOD${slots}" ;;
        # The unquoted expansion turns the lines into a list for the message
        *) log "several Zigbee modules are selected (slots $(echo ${slots} | tr ' ' ','));" \
               "one zigbee2mqtt works with one adapter, so set serial.port in" \
               "${Z2M_CONFIG_PATH} by hand" ;;
    esac
    exit 0
}

main "$@"
