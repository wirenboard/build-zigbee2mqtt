#!/bin/sh -e

# fpm runs this on a FRESH install only (generated postinst calls after_install
# when no previous version is configured); on upgrade it runs after-upgrade.sh
# instead. Both delegate to the shared helper, so the homeui integration (nginx
# gate + custom-menu entry) is placed in either case. Integration failures must
# not abort the package install, hence the `|| true`.
HELPER=/usr/share/zigbee2mqtt/wb-homeui-integration.sh
[ -f "$HELPER" ] && sh "$HELPER" || true

exit 0
