#!/bin/bash -xe

NPM_REGISTRY=${NPM_REGISTRY:-}

if [[ $# -lt 4 ]]; then
    echo >&2 "Usage: $0 <pkg_name> <version> <z2m_dir> <result_dir> [optional fpm flags]"
    echo >&2 "Env used:"
    echo -e >&2 "\tNODEJS_MAJOR_VERSION\tthe Node.js major to build with, required"
    echo -e >&2 "\tNPM_REGISTRY\tnpm registry address override"
    exit 2
fi

# No default: this decides both which Node.js the build runs on and what the package requires,
# and guessing it for the caller produces a package nobody asked for
if [[ -z ${NODEJS_MAJOR_VERSION:-} ]]; then
    echo >&2 "NODEJS_MAJOR_VERSION is not set: the Node.js major the build installs and the"
    echo >&2 "package requires, for example 24"
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

echo "Current APT configuration in wirenboard.list:"
cat /etc/apt/sources.list.d/wirenboard.list || echo "File doesn't exist"

# Turns a Node.js major version into the apt dependency the build and the package use
format_apt_dependency() {
    case "$1" in
        # zigbee2mqtt 1.18.1 needs Node 16, which ships as the separate package nodejs-16
        16) echo "nodejs-16" ;;
        # unix-dgram, the only native module built from source here, is compiled for the ABI of
        # the Node.js it was built with and does not load on another major, hence the upper bound
        *)  echo "nodejs (>= $1), nodejs (<< $(($1 + 1)))" ;;
    esac
}

# Installs the Node.js the package will require, or reports what the rootfs offers instead
install_nodejs() {
    local dependency=$1

    echo "Node.js available in the rootfs before the install:"
    apt-cache policy nodejs

    if ! apt-get satisfy -y "$dependency"; then
        echo >&2 "=== '$dependency' cannot be satisfied in this rootfs ==="
        apt-cache policy nodejs >&2
        echo >&2 "A version the repositories do not have yet can come from a testing set:"
        echo >&2 "  set WBDEV_TESTING_SETS=<name>, or pick another major from the list above"
        return 1
    fi

    echo "Node.js in the rootfs for this build: installed version and the repository it came from"
    apt-cache policy nodejs
}

apt-get update

# Node.js first: if the required version is missing, the build fails in seconds instead of
# after the minutes the toolchain below costs under emulation
NODEJS_DEPENDENCY=$(format_apt_dependency "$NODEJS_MAJOR_VERSION")
install_nodejs "$NODEJS_DEPENDENCY"

apt-get install -y git make g++ gcc ruby ruby-dev rubygems build-essential
gem install --no-document fpm -v 1.16.0

corepack enable pnpm
# Workaround: corepack enable creates a broken shim in some environments
# Always replace the shim with a wrapper to ensure it works correctly
printf '#!/bin/sh\nexec corepack pnpm "$@"\n' >/usr/bin/pnpm
chmod +x /usr/bin/pnpm

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
        echo "pnpm install failed."
        return 1
    fi

    if [[ "${PKG_NAME}" != "zigbee2mqtt-1.18.1" ]]; then
        pnpm run build  # required only for newer zigbee2mqtt to compile typescript
        if [[ $? -ne 0 ]]; then
            echo "pnpm run build failed."
            return 1
        fi

        pnpm prune --prod # remove devDependencies for minimise result size
        if [[ $? -ne 0 ]]; then
            echo "pnpm prune failed."
            return 1
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
	--deb-recommends 'wb-mqtt-zigbee | wb-zigbee2mqtt' \
    --maintainer 'Wiren Board Robot <info@wirenboard.com>' \
    --description 'Zigbee to MQTT bridge (package by Wiren Board team)' \
    --url 'https://www.zigbee2mqtt.io/' \
    --vendor 'Wiren Board' \
    --depends "$NODEJS_DEPENDENCY" \
    --before-upgrade package/before-upgrade.sh \
    --after-upgrade package/after-upgrade.sh \
    --package "$RESULT_SUBDIR/result.deb" \
    "$@" \
    "$PROJECT_SUBDIR"=/mnt/data/root

dpkg-name "$RESULT_SUBDIR/result.deb"
