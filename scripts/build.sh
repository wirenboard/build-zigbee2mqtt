#!/bin/bash
# Builds the zigbee2mqtt package: installs the Node.js the package will require and the toolchain,
# builds the application with pnpm and packs the result with fpm.
# Usage: build.sh <package name> <version> <sources dir> <result dir> [extra fpm flags]
# Env:   BUILD_AND_REQUIRE_NODEJS, the Node.js major to build with and to require, no default
#        NPM_REGISTRY, registry override, empty for the default one
# Exit:  0 package built, 1 a build step failed (the log names it), 2 usage
#        any other code comes from the command that failed under set -e, for example 100
#        from apt-get
#
# Runs inside "wbdev chroot". Every command is echoed: the build log is the only record of what
# happened in that rootfs.
#
# Version examples, as the Jenkinsfile passes them:
#   2.3.0-wb101                                        main with TAG=2.3.0
#   2.1.1-wb101~exp~feature+increase+nodejs~1~g6f19836  a branch
#   2.3.0-2-g9d1427c-wb101~exp~...                     a branch with no tag, version from git describe

set -euo pipefail
set -x

usage() { sed -n '2,7p' "$0" >&2; exit 2; }

parse_arguments() {
    [ $# -ge 4 ] || usage
    PKG_NAME=$1
    VERSION=$2
    SOURCES=$3
    RESULT_DIR=$4
    shift 4
    FPM_EXTRA=("$@")
    NPM_REGISTRY=${NPM_REGISTRY:-}

    # No default: this decides both which Node.js the build runs on and what the package requires,
    # and guessing it for the caller produces a package nobody asked for
    if [ -z "${BUILD_AND_REQUIRE_NODEJS:-}" ]; then
        echo >&2 "BUILD_AND_REQUIRE_NODEJS is not set: the Node.js major the build installs and the"
        echo >&2 "package requires, for example 24"
        exit 2
    fi
    [ -d "${SOURCES}" ] || { echo >&2 "no sources directory ${SOURCES}"; exit 2; }
}

# Turns a Node.js major version into the apt dependency the build and the package use
format_apt_dependency() {
    case "$1" in
        # zigbee2mqtt 1.18.1 needs Node 16, which ships as the separate package nodejs-16
        16) echo "nodejs-16" ;;
        # "unix-dgram", the only native module built from source here, is compiled for the ABI of
        # the Node.js it was built with and does not load on another major, hence the upper bound
        *)  echo "nodejs (>= $1), nodejs (<< $(($1 + 1)))" ;;
    esac
}

# Installs the Node.js the package will require, or reports what the rootfs offers instead
install_nodejs() {
    local dependency=$1
    # The package to look at: "nodejs (>= 24), nodejs (<< 25)" is about nodejs, major 16 is about
    # the separate package nodejs-16
    local package=${dependency%% *}

    echo "Node.js available in the rootfs before the install:"
    apt-cache policy "${package}"

    if ! apt-get satisfy -y "${dependency}"; then
        echo >&2 "=== '${dependency}' cannot be satisfied in this rootfs ==="
        apt-cache policy "${package}" >&2
        echo >&2 "Pick another major from the list above, or take the version from a testing set:"
        echo >&2 "  set WBDEV_TESTING_SETS=<name>. That parameter is for the controller targets:"
        echo >&2 "  wbdev writes the set into the rootfs, and an amd64 build runs in the devenv"
        echo >&2 "  container instead, so its Node.js has to be in dev-tools itself"
        return 1
    fi

    echo "Node.js in the rootfs for this build: installed version and the repository it came from"
    apt-cache policy "${package}"
}

install_toolchain() {
    apt-get install -y git make g++ gcc ruby ruby-dev rubygems build-essential
    gem install --no-document fpm -v 1.18.0
}

enable_pnpm() {
    corepack enable pnpm
    # Workaround: corepack enable creates a broken shim in some environments
    # Always replace the shim with a wrapper to ensure it works correctly
    printf '#!/bin/sh\nexec corepack pnpm "$@"\n' > /usr/bin/pnpm
    chmod +x /usr/bin/pnpm

    if [ -n "${NPM_REGISTRY}" ]; then
        echo "Override NPM registry"
        pnpm config set registry "${NPM_REGISTRY}"
    fi
}

# That old release names Node 15 as the newest it supports, and the package needs it to run on
# nodejs-16: https://github.com/Koenkk/zigbee2mqtt/pull/7297
allow_node_16_in_engines() {
    [ "${PKG_NAME}" = "zigbee2mqtt-1.18.1" ] || return 0
    sed -i 's#|| ^15#|| ^15 || ^16#' "${SOURCES}/package.json"
}

# The registry and the network fail often enough that one attempt at the dependencies is not a
# verdict. Compiling is another matter: the same sources fail the same way, so it runs once
install_dependencies() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if pnpm install --frozen-lockfile; then
            echo "Dependencies installed from ${attempt} tries"
            return 0
        fi
        echo "pnpm install failed, retry (${attempt} done)"
    done
    echo "pnpm install failed five times"
    return 1
}

build_application() {
    pushd "${SOURCES}" || exit 1
    install_dependencies || exit 1

    # zigbee2mqtt-1.18.1 is an old release kept as a package of its own, for installations that
    # stayed on it. It is plain JavaScript: TypeScript came to zigbee2mqtt later, so nothing here
    # has to be compiled
    if [ "${PKG_NAME}" != "zigbee2mqtt-1.18.1" ]; then
        pnpm run build || { echo "pnpm run build failed"; exit 1; }
        pnpm prune --prod || { echo "pnpm prune failed"; exit 1; }
    fi

    popd || exit 1
}

# The runtime configuration is deliberately not packaged. zigbee2mqtt rewrites
# "data/configuration.yaml" itself and keeps the network key, the pan id and the paired devices
# there, so it is state rather than a setting from the maintainer: as a dpkg conffile it
# produced the replace-or-keep prompt whenever the default changed, and an answered "replace"
# destroyed the Zigbee network. The package ships a template instead, and setup-z2m-config.sh
# creates the file on the controller when there is none.
pack_deb_with_fpm() {
    local dependency=$1

    mkdir -p "${RESULT_DIR}"

    # TODO: --deb-after-purge package/after-purge.sh, to wipe /mnt/data/root/zigbee2mqtt when the
    # package is purged. fpm 1.18.0 takes the flag and does nothing with it: the option handler
    # puts the path into attributes[:deb_after_purge], and nothing in fpm ever reads that attribute
    fpm --input-type dir \
        --output-type deb \
        --name "${PKG_NAME}" \
        --version "${VERSION}" \
        --exclude 'mnt/data/root/zigbee2mqtt/.git*' \
        --exclude 'mnt/data/root/zigbee2mqtt/.git/**' \
        --exclude 'mnt/data/root/zigbee2mqtt/data/configuration.yaml' \
        --deb-no-default-config-files \
        --deb-systemd package/zigbee2mqtt.service \
        --deb-systemd-auto-start \
        --deb-systemd-enable \
        --deb-recommends 'wb-mqtt-zigbee | wb-zigbee2mqtt' \
        --maintainer 'Wiren Board Robot <info@wirenboard.com>' \
        --description 'Zigbee to MQTT bridge (package by Wiren Board team)' \
        --url 'https://www.zigbee2mqtt.io/' \
        --vendor 'Wiren Board' \
        --depends "${dependency}" \
        --after-install package/after-install.sh \
        --before-upgrade package/before-upgrade.sh \
        --after-upgrade package/after-upgrade.sh \
        --package "${RESULT_DIR}/result.deb" \
        "${FPM_EXTRA[@]}" \
        "${SOURCES}"=/mnt/data/root \
        package/configuration.default.yaml=/usr/share/zigbee2mqtt/configuration.default.yaml \
        package/setup-z2m-config.sh=/usr/lib/zigbee2mqtt/setup-z2m-config.sh

    dpkg-name "${RESULT_DIR}/result.deb"
}

main() {
    parse_arguments "$@"

    echo "Current APT configuration in wirenboard.list:"
    cat /etc/apt/sources.list.d/wirenboard.list || echo "File doesn't exist"
    apt-get update

    # Node.js first: if the required version is missing, the build fails in seconds instead of
    # after the minutes the toolchain below costs under emulation
    local dependency
    dependency=$(format_apt_dependency "${BUILD_AND_REQUIRE_NODEJS}")
    install_nodejs "${dependency}"
    install_toolchain
    enable_pnpm

    allow_node_16_in_engines
    build_application
    pack_deb_with_fpm "${dependency}"
}

main "$@"
