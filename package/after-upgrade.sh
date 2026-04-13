#!/bin/sh -e

CONFIG_FILE=/mnt/data/root/zigbee2mqtt/data/configuration.yaml

echo "Adding dependencies for pnpm"
# Dependencies already included in .deb — this just prevents runtime issues
pnpm install --prod --frozen-lockfile --force --prefix /mnt/data/root/zigbee2mqtt

# Restore user configuration saved before upgrade
if [ -e "$CONFIG_FILE.wb-upgrade-backup" ]; then
    echo "Restoring configuration file after upgrade"
    mv "$CONFIG_FILE.wb-upgrade-backup" "$CONFIG_FILE"
fi

# Legacy: restore config from old malformed package (without conffile mark)
if [ -e "$CONFIG_FILE.wb-old" ]; then
    echo "Restoring config file after upgrade from old malformed zigbee2mqtt package version"
    mv "$CONFIG_FILE.wb-old" "$CONFIG_FILE"
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

if ! grep -q '^availability:' "$CONFIG_FILE"; then
  cat >> "$CONFIG_FILE" <<'EOF'
availability:
  enabled: true
  active:
    timeout: 10
    max_jitter: 30000
    backoff: true
EOF
  echo "availability section added to the configuration file"
fi
