#!/bin/bash -xe

NPM_REGISTRY=${NPM_REGISTRY:-}
FPM_DEPENDS=${FPM_DEPENDS:-"nodejs (>= 22)"}
USE_UNSTABLE_DEPS=${USE_UNSTABLE_DEPS:-}

if [[ $# -lt 4 ]]; then
    echo >&2 "Usage: $0 <pkg_name> <version> <z2m_dir> <result_dir> [optional fpm flags]"
    echo >&2 "Env used:"
    echo -e >&2 "\tFPM_DEPENDS\tdependencies"
    echo -e >&2 "\tNPM_REGISTRY\tnpm registry address override"
    echo -e >&2 "\tUSE_UNSTABLE_DEPS\tuse testing repositories if set to 'y'"
    exit 2
fi

# Call example from wirenboard/build-zigbee2mqtt repo Jenkins branches:
#   ./build.sh zigbee2mqtt <!VERSION!> zigbee2mqtt result
# VERSION incert examples:
# - Build from branch "main" with set TAG = 2.3.0:
#   "2.3.0-wb101"
# - Build from custom branch "feature/increase-nodejs-to-22":
#   "2.1.1-wb101~exp~feature+increase+nodejs+to+22~1~g6f19836"
# - Build from custom branch "feature/increase-nodejs-to-22" without set TAG and use latest tag:
#   "2.3.0-2-g9d1427c-wb101~exp~feature+increase+nodejs+to+22~6~gcdf2584"
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

echo "Current APT configuration:"
cat /etc/apt/sources.list.d/wirenboard.list || echo "File doesn't exist"
if [[ "$USE_UNSTABLE_DEPS" == "y" ]]; then
    echo "Using testing repositories as requested."
    if [ -f /etc/apt/sources.list.d/wirenboard.list ]; then
        echo "wirenboard.list file already exists, removing it"
        rm /etc/apt/sources.list.d/wirenboard.list
    fi
    echo "Creating wirenboard.list file with testing repository"
    echo "deb http://deb.wirenboard.com/wb7/bullseye testing main" > /etc/apt/sources.list.d/wirenboard.list
fi

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

pnpm_build() {
    pnpm install --frozen-lockfile # install all dependencies include dev
    if [[ $? -ne 0 ]]; then
        echo "pnpm install failed, exiting."
        exit 1
    fi

    if [[ "${PKG_NAME}" != "zigbee2mqtt-1.18.1" ]]; then
        pnpm run build  # required only for newer zigbee2mqtt to compile typescript
        if [[ $? -ne 0 ]]; then
            echo "pnpm run build failed, exiting."
            exit 1
        fi

        pnpm prune --prod # remove devDependencies for minimise result size
        if [[ $? -ne 0 ]]; then
            echo "pnpm prune failed, exiting."
            exit 1
        fi
    fi
}

BUILD_DONE=false
for i in {1..5}; do
    if pnpm_build; then
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
    --exclude 'mnt/data/root/zigbee2mqtt/.git/**' \
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
