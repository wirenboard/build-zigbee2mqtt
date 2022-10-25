#!/bin/bash -xe

NPM_REGISTRY=${NPM_REGISTRY:-}

if [[ $# -lt 4 ]]; then
    echo >&2 "Usage: $0 <pkg_name> <version> <z2m_dir> <result_dir> [optional fpm flags]"
    echo >&2 "Env used:"
    echo -e >&2 "\tNPM_REGISTRY\tnpm registry address override"
    exit 2
fi

PKG_NAME=$1
VERSION=$2
PROJECT_SUBDIR=$3
RESULT_SUBDIR=$4
shift 4

if [[ ! -d "$PROJECT_SUBDIR" ]]; then
    echo "No project subdirectory $PROJECT_SUBDIR"
    exit 2
fi

echo "Prepare environment"
apt-get update
apt-get install -y nodejs git make g++ gcc ruby ruby-dev rubygems build-essential
gem install --no-document fpm -v 1.12.0
                        
if [[ -n "$NPM_REGISTRY" ]]; then
    echo "Override NPM registry"
    npm set registry "$NPM_REGISTRY"
fi

pushd "$PROJECT_SUBDIR" || exit 1
npm audit fix
npm ci -d
npm run build -d || true  # required only for newer zigbee2mqtt to compile typescript
popd || exit 1

mkdir -p "$RESULT_SUBDIR"

fpm -s dir -t deb -n "$PKG_NAME" \
    --exclude 'mnt/data/root/zigbee2mqtt/.git*' \
    --config-files mnt/data/root/zigbee2mqtt/data/configuration.yaml \
    --deb-no-default-config-files \
    --deb-systemd package/zigbee2mqtt.service \
    --deb-recommends wb-zigbee2mqtt \
    -m 'Wiren Board Robot <info@wirenboard.com>' \
    --description 'Zigbee to MQTT bridge (package by Wiren Board team)' \
    --url 'https://www.zigbee2mqtt.io/' \
    --vendor 'Wiren Board' \
    -d 'nodejs (>= 16.18.0)' \
    --before-upgrade package/before-upgrade.sh \
    --after-upgrade package/after-upgrade.sh \
    -p "$RESULT_SUBDIR/${PKG_NAME}_${VERSION}_armhf.deb" \
    -v "$VERSION" \
    "$@" \
    "$PROJECT_SUBDIR"=/mnt/data/root
