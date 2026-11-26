#!/bin/sh
# Runs on the controller after an upgrade unpacked the new package. fpm inlines it into a
# maintainer script function, where a failing command does not stop the upgrade

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

# The configuration does not travel in the package, so nothing is saved before the upgrade and
# nothing is restored here. This creates it when there is none and fills in the serial port
/usr/lib/zigbee2mqtt/setup-z2m-config.sh

# Keys the package has started to rely on reach existing configurations only from here: the file
# belongs to the user now, and a changed template does not travel to controllers by itself
# The file has to exist for the two blocks below: setup-z2m-config.sh never fails, and without
# this check "cat >>" would create a configuration holding nothing but "availability:"
if [ -e "${CONFIG_FILE}" ] && ! grep -Pzq 'serial:\n(  .*\n)*  adapter: zstack' "${CONFIG_FILE}"; then
    LINE=$(awk '
        /^serial:/ { inside=1; next }
        inside && /^[^ ]/ { exit }
        inside { last_line = NR }
        END { print last_line }
    ' "${CONFIG_FILE}")

    if [ -n "${LINE}" ]; then
        sed -i "${LINE}a \  adapter: zstack" "${CONFIG_FILE}"
    else
        sed -i "/^serial:/a \  adapter: zstack" "${CONFIG_FILE}"
    fi
    echo "zigbee2mqtt: zstack adapter type added to the configuration"
fi

if [ -e "${CONFIG_FILE}" ] && ! grep -q '^availability:' "${CONFIG_FILE}"; then
    cat >> "${CONFIG_FILE}" <<'EOF'
availability:
  enabled: true
  active:
    timeout: 10
    max_jitter: 30000
    backoff: true
EOF
    echo "zigbee2mqtt: availability section added to the configuration"
fi

# Since 2.14.2-wb102 the template points zigbee2mqtt at the unix socket of the local mosquitto
# instead of TCP on localhost. A configuration moves along only when it still carries the address
# every earlier package wrote, mqtt://localhost: any other address is somebody's choice. And only
# on the upgrade that crosses that version, so that a user who puts mqtt://localhost back keeps
# it on the next upgrades. fpm passes the version being replaced as $1
MQTT_SOCKET_DEFAULT_SINCE=2.14.2-wb102
MQTT_OLD_DEFAULT_SERVER=mqtt://localhost
MQTT_SOCKET_PATH=/var/run/mosquitto/mosquitto.sock
MQTT_SOCKET_SERVER="mqtt+unix://${MQTT_SOCKET_PATH}"
if [ -e "${CONFIG_FILE}" ] && [ -n "${1:-}" ] &&
   dpkg --compare-versions "$1" lt "${MQTT_SOCKET_DEFAULT_SINCE}"
then
    # The server out of the mqtt: block only, without quotes and without the CR of the files
    # earlier packages wrote with CRLF
    MQTT_SERVER=$(awk -v q="'" '
        /^[^[:space:]#]/           { in_mqtt = ($0 ~ /^mqtt:/) }
        in_mqtt && $1 == "server:" { v = $2; sub(/\r$/, "", v); gsub(q, "", v); gsub(/"/, "", v)
                                     print v; exit }
    ' "${CONFIG_FILE}" 2>/dev/null)

    if [ "${MQTT_SERVER}" != "${MQTT_OLD_DEFAULT_SERVER}" ]; then
        echo "zigbee2mqtt: mqtt.server left as ${MQTT_SERVER:-unset}, not the old default"
    # The listener is looked for in the configuration of mosquitto, not as a socket file: during
    # an upgrade mosquitto may be restarting and the file be gone for a moment. Without such a
    # listener zigbee2mqtt would not connect at all, and TCP on localhost is what works there
    elif ! grep -rqsE '^[[:space:]]*listener[[:space:]]+0[[:space:]]+(/var)?/run/mosquitto/mosquitto\.sock[[:space:]]*$' \
              /etc/mosquitto
    then
        echo "zigbee2mqtt: mqtt.server left as ${MQTT_SERVER}, mosquitto has no listener on" \
             "${MQTT_SOCKET_PATH}"
    elif awk -v server="'${MQTT_SOCKET_SERVER}'" '
             /^[^[:space:]#]/                       { in_mqtt = ($0 ~ /^mqtt:/) }
             in_mqtt && $1 == "server:" && !written { cr = sub(/\r$/, "")
                                                      sub(/server:.*/, "server: " server)
                                                      if (cr) $0 = $0 "\r"
                                                      written = 1 }
                                                    { print }
         ' "${CONFIG_FILE}" > "${CONFIG_FILE}.wb-new" &&
         mv "${CONFIG_FILE}.wb-new" "${CONFIG_FILE}"
    then
        echo "zigbee2mqtt: mqtt.server moved from ${MQTT_SERVER} to ${MQTT_SOCKET_SERVER}," \
             "takes effect on the next start of the service"
    else
        rm -f "${CONFIG_FILE}.wb-new"
        echo "zigbee2mqtt: warning: could not move mqtt.server to ${MQTT_SOCKET_SERVER}," \
             "left as ${MQTT_SERVER}"
    fi
fi
