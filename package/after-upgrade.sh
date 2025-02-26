#!/bin/sh -e

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

echo "Adding dependencies for pnpm"
pnpm install --frozen-lockfile --prefix /mnt/data/root/zigbee2mqtt

if [ -e "$CONFIG_FILE.wb-old" ]; then
    echo "Restoring config file after upgrade from old malformed zigbee2mqtt package version"
    mv $CONFIG_FILE.wb-old $CONFIG_FILE
fi

if ! grep -Pzq 'serial:\n(  .*\n)*  adapter: zstack' $CONFIG_FILE; then
  LINE=$(awk '
    /^serial:/ { inside=1; next }
    inside && /^[^ ]/ { exit }
    inside { last_line = NR }
    END { print last_line }
  ' "$CONFIG_FILE")

  if [ -n "$LINE" ]; then
    sed -i "${LINE}a \  adapter: zstack" $CONFIG_FILE
  else
    sed -i "/^serial:/a \  adapter: zstack" $CONFIG_FILE
  fi
  echo "zstack adapter type added to the configuration file"
fi
