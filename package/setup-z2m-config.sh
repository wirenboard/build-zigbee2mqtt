#!/bin/sh
# Creates the zigbee2mqtt configuration from the template when the controller has none, and sets
# the serial port from the slot picked in the web interface. The template carries /dev/ttyMOD0,
# a slot no controller has, so a port nobody has set is visible as such.
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
        log "warning: no ${Z2M_CONFIG_TEMPLATE_PATH}, the configuration is not created"
        return 0
    }

    if mkdir -p "$(dirname "${Z2M_CONFIG_PATH}")" &&
       cp "${Z2M_CONFIG_TEMPLATE_PATH}" "${Z2M_CONFIG_PATH}"
    then
        log "created ${Z2M_CONFIG_PATH} from the template"
    else
        log "warning: could not create ${Z2M_CONFIG_PATH} from the template"
    fi
}

# read_serial_port <path>: the port out of the serial: block, and out of that block only,
# because a configuration may well carry a frontend: port too. Earlier packages wrote the file
# with CRLF, hence the sub()
read_serial_port() {
    awk '
        /^[^[:space:]#]/           { in_serial = ($0 ~ /^serial:/) }
        in_serial && $1 == "port:" { sub(/\r$/, "", $2); print $2; exit }
    ' "$1" 2>/dev/null
}

# write_serial_port <path> <port>: replaces the port in the serial: block, keeps the indentation
write_serial_port() {
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

# set_port_from_slot <slot> <port in the configuration>: the slot picked in the settings wins, so
# a module moved to another slot is picked up on the next start of the service. A controller has
# slots 1 to 4, anything else in the settings is a mistake and changes nothing
set_port_from_slot() {
    case "$1" in
        [1-4]) ;;
        *) log "${WB_HARDWARE_CONFIG_PATH} names slot $1, a controller has 1 to 4," \
               "serial.port left as $2"
           return 0 ;;
    esac

    port="/dev/ttyMOD$1"
    [ "$2" = "${port}" ] && return 0

    # A port that is not a slot of this controller belongs to a USB stick or to a coordinator
    # over the network. Whoever wrote it did not mean the module in the settings
    case "$2" in
        ""|/dev/ttyMOD[0-9]) ;;
        *) log "serial.port left as $2, not a slot of this controller;" \
               "${WB_HARDWARE_CONFIG_PATH} points to ${port}"
           return 0 ;;
    esac

    write_serial_port "${Z2M_CONFIG_PATH}" "${port}" &&
        log "serial.port set to ${port}, the Zigbee module slot from" \
            "${WB_HARDWARE_CONFIG_PATH}, picked in the web interface"
}

main() {
    create_z2m_config_if_missing
    [ -e "${Z2M_CONFIG_PATH}" ] || exit 0

    slots=$(get_slots_with_zigbee_module)
    current_port=$(read_serial_port "${Z2M_CONFIG_PATH}")
    # grep prints 0 when it matches nothing, so the count is right even for an empty list
    case "$(printf '%s\n' "${slots}" | grep -c '[0-9]')" in
        0) log "no Zigbee module in ${WB_HARDWARE_CONFIG_PATH}, where the web interface" \
               "writes the slot, serial.port left as ${current_port}" ;;
        1) set_port_from_slot "${slots}" "${current_port}" ;;
        # The unquoted expansion turns the lines into a list for the message
        *) log "several Zigbee modules in ${WB_HARDWARE_CONFIG_PATH} (slots" \
               "$(echo ${slots} | tr ' ' ',')), serial.port left as ${current_port}" ;;
    esac
    exit 0
}

main "$@"
