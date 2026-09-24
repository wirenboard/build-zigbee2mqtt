#!/bin/sh
# Runs on the controller after an upgrade unpacked the new package. fpm inlines it into a
# maintainer script function, where a failing command does not stop the upgrade

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

# The configuration does not travel in the package, so nothing is saved before the upgrade and
# nothing is restored here. This creates it when there is none and fills in the serial port
/usr/lib/zigbee2mqtt/setup-z2m-config.sh

echo "Adding dependencies for pnpm"
# Dependencies already included in .deb — this just prevents runtime issues
pnpm install --prod --frozen-lockfile --force --prefix /mnt/data/root/zigbee2mqtt

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
    echo "zstack adapter type added to the configuration file"
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
    echo "availability section added to the configuration file"
fi
