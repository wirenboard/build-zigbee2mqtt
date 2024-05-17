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
apt-get install -y git make g++ gcc ruby ruby-dev rubygems build-essential

if [[ "${PKG_NAME}" == "zigbee2mqtt-1.18.1" ]]; then
	apt install -y nodejs
else
	# add node 20 repo and install nodejs 20
	# echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x bullseye main" >> /etc/apt/sources.list.d/nodesource.list
	# apt update
	curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
	# figure out the version of nodejs 20 since apt does not support >= in version
	nodejs20_version=$(apt policy nodejs | grep -v "Candidate:" | grep "1nodesource1" | awk '{print $1}' | grep "^20." | head -n 1)
	apt install -y nodejs="$nodejs20_version"
fi

ls -la /usr/lib/node_modules
ls -la /usr/lib/node_modules/npm/
ls -la /usr/lib/node_modules/npm/lib
ls -la /usr/lib/node_modules/npm/lib/es6

gem install --no-document fpm -v 1.14.2

if [[ -n "$NPM_REGISTRY" ]]; then
    echo "Override NPM registry"
    npm set registry "$NPM_REGISTRY"
fi

pushd "$PROJECT_SUBDIR" || exit 1

# Include nodejs version 16 to supported engines
# https://github.com/Koenkk/zigbee2mqtt/pull/7297
if [[ "${PKG_NAME}" == "zigbee2mqtt-1.18.1" ]]; then
    sed -i 's#|| ^15#|| ^15 || ^16#' package.json
fi

whereis npm

npm_build() {
    npm ci -d
    if [[ "${PKG_NAME}" != "zigbee2mqtt-1.18.1" ]]; then
        npm run build -d  # required only for newer zigbee2mqtt to compile typescript
    fi
}

BUILD_DONE=false
for i in {1..5}; do
    if npm_build; then
        echo "Build done from $i tries!"
        BUILD_DONE=true
        break
    else
        echo "Build FAILED, retry ($i done)"
    fi
done

if ! $BUILD_DONE; then
    echo "Build FAILED!"
    exit 1
fi

popd || {
    echo "Failed to pop dir"
    exit 1
}

cp -f package/configuration.yaml $PROJECT_SUBDIR/data/configuration.yaml

mkdir -p "$RESULT_SUBDIR"

fpm -s dir -t deb -n "$PKG_NAME" \
    --exclude 'mnt/data/root/zigbee2mqtt/.git*' \
    --config-files mnt/data/root/zigbee2mqtt/data/configuration.yaml \
    --deb-no-default-config-files \
    --deb-systemd package/zigbee2mqtt.service \
    --deb-systemd-auto-start \
    --deb-systemd-enable \
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
