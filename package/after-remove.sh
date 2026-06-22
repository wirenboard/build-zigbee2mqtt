#!/bin/sh -e

# Remove the nginx drop-ins and the homeui menu entry that after-install.sh
# placed outside the package's own dpkg file list, then reload nginx. Only on a
# real removal/purge — not on upgrade, where the new version re-places them.

NGINX_WB_D=/etc/nginx/includes/default.wb.d
NGINX_CONF_D=/etc/nginx/conf.d
MENU_DIR=/usr/share/wb-mqtt-homeui/custom-menu

case "$1" in
    remove|purge)
        rm -f "$NGINX_WB_D/wb-zigbee2mqtt.conf" \
              "$NGINX_CONF_D/wb-zigbee2mqtt-auth-cache.conf" \
              "$MENU_DIR/wb-zigbee2mqtt.json"
        if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
            invoke-rc.d nginx reload >/dev/null 2>&1 || systemctl reload nginx >/dev/null 2>&1 || true
        fi
        ;;
esac

exit 0
