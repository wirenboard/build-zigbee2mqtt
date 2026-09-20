#!/bin/bash
# Builds the zigbee2mqtt package: installs the Node.js the package will require and the toolchain,
# builds the application with pnpm and packs the result with fpm.
# Usage: build.sh [--step build|pack] <package name> <version> <sources dir> <result dir> [extra fpm flags]
#        --step build  install Node.js and the toolchain, build the application, and stop
#        --step pack   install fpm and pack a tree built earlier
#        no --step     both, as one run, the way a build by hand does it
# The two steps exist so that the job can clean the built tree between them: scripts/prune-files.sh
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

usage() { sed -n '2,11p' "$0" >&2; exit 2; }

parse_arguments() {
    STEP=all
    if [ "${1:-}" = "--step" ]; then
        STEP=${2:-}
        case "${STEP}" in build|pack) ;; *) usage ;; esac
        shift 2
    fi
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

install_build_tools() {
    apt-get install -y git make g++ gcc build-essential
}

install_fpm() {
    apt-get install -y ruby ruby-dev rubygems
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

# TEMPORARY, goes away with package/backup-z2m-data.sh. dpkg calls one of the two preinst
# functions fpm generates, so the copy of the data has to be in both. Writes the pair into the
# file named by the caller, who removes it once fpm has read it
before_upgrade_with_backup() {
    cat package/backup-z2m-data.sh package/before-upgrade.sh > "$1"
}

# The runtime configuration is deliberately not packaged. zigbee2mqtt rewrites
# "data/configuration.yaml" itself and keeps the network key, the pan id and the paired devices
# there, so it is state rather than a setting from the maintainer: as a dpkg conffile it
# produced the replace-or-keep prompt whenever the default changed, and an answered "replace"
# destroyed the Zigbee network. The package ships a template instead, and setup-z2m-config.sh
# creates the file on the controller when there is none.
pack_deb_with_fpm() {
    local dependency=$1
    local before_upgrade="${RESULT_DIR}/.before-upgrade-with-backup.sh"

    mkdir -p "${RESULT_DIR}"
    before_upgrade_with_backup "${before_upgrade}"

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
        --before-install package/backup-z2m-data.sh \
        --before-upgrade "${before_upgrade}" \
        --after-upgrade package/after-upgrade.sh \
        --package "${RESULT_DIR}/result.deb" \
        "${FPM_EXTRA[@]}" \
        "${SOURCES}"=/mnt/data/root \
        package/configuration.default.yaml=/usr/share/zigbee2mqtt/configuration.default.yaml \
        package/setup-z2m-config.sh=/usr/lib/zigbee2mqtt/setup-z2m-config.sh

    rm -f "${before_upgrade}"
    dpkg-name "${RESULT_DIR}/result.deb"
}

build_step() {
    local dependency=$1

    echo "Current APT configuration in wirenboard.list:"
    cat /etc/apt/sources.list.d/wirenboard.list || echo "File doesn't exist"
    apt-get update

    # Node.js first: if the required version is missing, the build fails in seconds instead of
    # after the minutes the toolchain below costs under emulation
    install_nodejs "${dependency}"
    install_build_tools
    enable_pnpm

    allow_node_16_in_engines
    build_application
}

pack_step() {
    local dependency=$1

    # node_modules, not dist: zigbee2mqtt-1.18.1 is plain JavaScript and builds no dist
    [ -d "${SOURCES}/node_modules" ] || {
        echo >&2 "${SOURCES} is not built: run build.sh --step build first"
        exit 1
    }
    # The job removes what a controller cannot use in a step of its own, between the two halves
    bash "$(dirname "$0")/prune-files.sh" --check "${SOURCES}"

    apt-get update
    install_fpm
    pack_deb_with_fpm "${dependency}"
}

main() {
    parse_arguments "$@"

    local dependency
    dependency=$(format_apt_dependency "${BUILD_AND_REQUIRE_NODEJS}")

    case "${STEP}" in
        build) build_step "${dependency}" ;;
        pack)  pack_step  "${dependency}" ;;
        all)   build_step "${dependency}"; pack_step "${dependency}" ;;
    esac
}

main "$@"
