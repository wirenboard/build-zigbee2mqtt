#!/bin/bash -xe

if [[ $# -lt 4 ]]; then
    echo >&2 "Usage: $0 <pkg_name> <version> <z2m_dir> <result_dir> [optional fpm flags]"
    echo >&2 "Env used:"
    echo -e >&2 "\tFPM_DEPENDS\tdependencies"
    echo -e >&2 "\tNPM_REGISTRY\tnpm registry address override"
    exit 2
fi

# Call example:
# - Build from main branch
#   ./build.sh zigbee2mqtt 2.3.0-wb101 zigbee2mqtt result
# - Build from custom branch
#   ./build.sh zigbee2mqtt 2.1.1-wb101~exp~feature+increase+nodejs+to+22~1~g6f19836 
PKG_NAME=$1
VERSION=$2
PROJECT_SUBDIR=$3
RESULT_SUBDIR=$4
shift 4

if [[ ! -d "$PROJECT_SUBDIR" ]]; then
    echo "No project subdirectory $PROJECT_SUBDIR"
    exit 2
fi

NPM_REGISTRY=${NPM_REGISTRY:-}

BASE_VERSION=$(echo "$VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
echo "Full version: $VERSION, Base version: $BASE_VERSION"
if dpkg --compare-versions "$BASE_VERSION" le "2.1.1"; then
    NODEJS_MIN_VERSION="20"
else
    NODEJS_MIN_VERSION="22"
fi
FPM_DEPENDS=${FPM_DEPENDS:-"nodejs (>= ${NODEJS_MIN_VERSION})"}
echo "Building zigbee2mqtt $VERSION (base: $BASE_VERSION) with Node.js ${NODEJS_MIN_VERSION}+ dependency"

echo "Prepare environment"
apt-get update
apt-get install -y git make g++ gcc ruby ruby-dev rubygems build-essential
apt-get satisfy -y "$FPM_DEPENDS"
gem install --no-document fpm -v 1.16.0

corepack enable pnpm

if [[ -n "$NPM_REGISTRY" ]]; then
    echo "Override NPM registry"
    pnpm config set registry "$NPM_REGISTRY"
fi

pushd "$PROJECT_SUBDIR" || exit 1

# Include nodejs version 16 to supported engines
# https://github.com/Koenkk/zigbee2mqtt/pull/7297
if [[ "${PKG_NAME}" == "zigbee2mqtt-1.18.1" ]]; then
    sed -i 's#|| ^15#|| ^15 || ^16#' package.json
fi

npm_build() {
    pnpm install --frozen-lockfile
    if [[ $? -ne 0 ]]; then
        echo "npm ci failed, exiting."
        exit 1
    fi
    if [[ "${PKG_NAME}" != "zigbee2mqtt-1.18.1" ]]; then
        pnpm run build  # required only for newer zigbee2mqtt to compile typescript
        if [[ $? -ne 0 ]]; then
            echo "npm run build failed, exiting."
            exit 1
        fi
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

cp -f package/configuration.yaml "$PROJECT_SUBDIR/data/configuration.yaml"

mkdir -p "$RESULT_SUBDIR"

fpm --input-type dir \
    --output-type deb \
    --name "$PKG_NAME" \
    --version "$VERSION" \
    --exclude 'mnt/data/root/zigbee2mqtt/.git*' \
    --config-files mnt/data/root/zigbee2mqtt/data/configuration.yaml \
    --deb-no-default-config-files \
    --deb-systemd package/zigbee2mqtt.service \
    --deb-systemd-auto-start \
    --deb-systemd-enable \
    --deb-recommends wb-zigbee2mqtt \
    --maintainer 'Wiren Board Robot <info@wirenboard.com>' \
    --description 'Zigbee to MQTT bridge (package by Wiren Board team)' \
    --url 'https://www.zigbee2mqtt.io/' \
    --vendor 'Wiren Board' \
    --depends "$FPM_DEPENDS" \
    --before-upgrade package/before-upgrade.sh \
    --after-upgrade package/after-upgrade.sh \
    --package "$RESULT_SUBDIR/result.deb" \
    "$@" \
    "$PROJECT_SUBDIR"=/mnt/data/root

dpkg-name "$RESULT_SUBDIR/result.deb"
