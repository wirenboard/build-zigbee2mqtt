#!/bin/sh -e

# Wire the zigbee2mqtt frontend into the homeui web UI:
#   * nginx drop-ins that gate the frontend behind the homeui session — the
#     default.wb.d/ snippet sits inside the homeui server block (so the session
#     cookie reaches auth_request), the cache zone goes into conf.d/;
#   * a homeui custom-menu entry under "Integrations".
#
# Idempotent. Invoked from BOTH after-install.sh (fresh install) and
# after-upgrade.sh (upgrade): fpm's generated postinst runs only one of those
# per package operation (after_install when no prior version is configured,
# after_upgrade otherwise), so the integration must be placed from each path to
# cover install and upgrade alike.

SHARE=/usr/share/zigbee2mqtt
NGINX_WB_D=/etc/nginx/includes/default.wb.d
NGINX_CONF_D=/etc/nginx/conf.d
GATE_SRC="$SHARE/nginx/wb-zigbee2mqtt.conf"
CACHE_SRC="$SHARE/nginx/wb-zigbee2mqtt-auth-cache.conf"
GATE_DST="$NGINX_WB_D/wb-zigbee2mqtt.conf"
CACHE_DST="$NGINX_CONF_D/wb-zigbee2mqtt-auth-cache.conf"

reload_nginx() {
    invoke-rc.d nginx reload >/dev/null 2>&1 || systemctl reload nginx >/dev/null 2>&1 || \
        echo "zigbee2mqtt: nginx reload failed; the gate may need a manual 'systemctl reload nginx'." >&2
}

# nginx gate — only when the homeui drop-in dir exists (wb-mqtt-homeui present).
# Validate before committing: if nginx -t fails, roll the drop-ins back so a bad
# snippet can never take homeui down.
if [ -d "$NGINX_WB_D" ] && [ -f "$GATE_SRC" ] && [ -f "$CACHE_SRC" ]; then
    cp "$GATE_SRC" "$GATE_DST"
    cp "$CACHE_SRC" "$CACHE_DST"
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then
            reload_nginx
        else
            echo "zigbee2mqtt: nginx config test failed; removing the drop-ins to protect homeui." >&2
            rm -f "$GATE_DST" "$CACHE_DST"
        fi
    fi
fi

# homeui menu entry. External-link menu support (the isExternal flag) landed in
# wb-mqtt-homeui 2.230.0; on older homeui the entry would render as a broken
# in-app route, so gate on the version. The openInNewTab flag (open in a reused
# named tab) is honoured only by homeui builds that support it; elsewhere it is
# ignored and the link opens in the same tab (graceful).
MENU_SRC="$SHARE/custom-menu/wb-zigbee2mqtt.json"
MENU_DIR=/usr/share/wb-mqtt-homeui/custom-menu
if [ -f "$MENU_SRC" ] && [ -d "$MENU_DIR" ]; then
    HOMEUI_VER=$(dpkg-query -W -f='${Version}' wb-mqtt-homeui 2>/dev/null || true)
    if [ -n "$HOMEUI_VER" ] && dpkg --compare-versions "$HOMEUI_VER" ge "2.230.0~"; then
        cp "$MENU_SRC" "$MENU_DIR/wb-zigbee2mqtt.json"
    fi
fi

exit 0
