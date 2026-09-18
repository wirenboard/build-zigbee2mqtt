#!/bin/bash
# Checks the built zigbee2mqtt package before it goes anywhere: control fields, contents, and that
# the native modules inside it load on the Node.js the package requires.
# Usage: test-deb.sh <result dir>
# Env:   BUILD_AND_REQUIRE_NODEJS, the major the package has to depend on
# Exit:  0 all checks passed, 1 a check failed (the summary names it), 2 usage or a broken suite list
#
# Runs inside `wbdev chroot` right after build.sh, where that Node.js is already installed.
# One test is one function named test_*; the suites at the bottom say which of them run and in
# which order. A test listed in no suite stops the run, because a test nobody calls looks like a
# passing one.

set -u

### the command line

usage() { sed -n '2,6p' "$0" >&2; exit 2; }

parse_arguments() {
    [ $# -eq 1 ] || usage
    RESULT_DIR=$1
    [ -d "${RESULT_DIR}" ] || { echo "${RESULT_DIR}: no such directory" >&2; exit 2; }
    [ -n "${BUILD_AND_REQUIRE_NODEJS:-}" ] || { echo "BUILD_AND_REQUIRE_NODEJS is not set" >&2; exit 2; }
    DEB=''
    for file in "${RESULT_DIR}"/*.deb; do
        [ -f "${file}" ] || continue
        # Absolute: apt reads "dir/file.deb" as the package "dir" from the release "file.deb",
        # and a bare name as a package name. Only a path of its own is treated as a file
        DEB=$(readlink -f "${file}")
        break
    done
    [ -n "${DEB}" ] || { echo "no .deb in ${RESULT_DIR}: build.sh has to run first" >&2; exit 2; }
    ARCH=$(dpkg --print-architecture)
    APP=/mnt/data/root/zigbee2mqtt
}

### reporting

check() {   # check <what> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASSED=$((PASSED + 1)); echo "ok    $1: $3"
    else
        FAILED=$((FAILED + 1)); echo "FAIL  $1: got '$3', expected '$2'"
    fi
}
skip()    { SKIPPED=$((SKIPPED + 1)); echo "skip  $1"; }
info()    { echo "info  $1: $2"; }
section() { echo; echo "=== $* ==="; }

### tools

yes_no()       { if "$@"; then echo yes; else echo no; fi; }
deb_field()    { dpkg-deb --field "${DEB}" "$1"; }
deb_contents() { dpkg-deb --contents "${DEB}"; }
# Runs node in the installed application, the way the service does
run_node_in_app()       { ( cd "${APP}" && timeout 120 node -e "$1" 2>&1 ); }

# ok, or the reason the module did not load, out of a multi-line stack
module_loads() {
    output=$(run_node_in_app "$1")
    if [ "$(tail -1 <<<"${output}")" = ok ]; then
        echo ok
        return
    fi
    flat=$(tr '\n' ' ' <<<"${output}" | tr -s ' ')
    # A module built for another major is the failure worth naming, and its two numbers say it all
    # shellcheck disable=SC2046
    set -- $(grep -o 'NODE_MODULE_VERSION [0-9]*' <<<"${flat}" | awk '{ print $2 }')
    if [ $# -ge 2 ]; then
        echo "built for NODE_MODULE_VERSION $1, this Node.js requires $2"
    else
        # The path inside the message is long and says nothing here
        sed "s|'[^']*'|the module|" <<<"${flat}" | grep -o 'Error:.\{0,120\}' || tail -1 <<<"${output}"
    fi
}

# The dependency the package must carry. Spelled out here, not taken from build.sh: a test that
# repeats the code it checks proves nothing
expected_dependency() {
    case "${BUILD_AND_REQUIRE_NODEJS}" in
        16) echo "nodejs-16" ;;
        *)  echo "nodejs (>= ${BUILD_AND_REQUIRE_NODEJS}), nodejs (<< $((BUILD_AND_REQUIRE_NODEJS + 1)))" ;;
    esac
}

need_command() {
    command -v "$1" > /dev/null && return 0
    skip "${CURRENT}: no $1 here"
    return 1
}

# The package is installed for real, as on a controller. In this rootfs there is no systemd, and
# the maintainer script of a fresh install tolerates that: every systemctl call ends with || true
install_package() {
    cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 0755 /usr/sbin/policy-rc.d
    apt-get install -y "${DEB}" || { echo "FAIL  the package does not install, nothing else can be checked"; exit 1; }
    rm -f /usr/sbin/policy-rc.d
}

### the package itself

test_control_fields() {
    check "package name" "zigbee2mqtt" "$(deb_field Package | sed 's/-[0-9].*//')"
    check "architecture" "${ARCH}"       "$(deb_field Architecture)"
    info  "version"      "$(deb_field Version)"
}

# The native modules are built for one ABI, so the package must not install on another major
test_depends_on_expected_node() {
    check "depends on the Node.js it was built with" "$(expected_dependency)" "$(deb_field Depends)"
}

test_contents() {
    contents=$(deb_contents)
    check "application in ${APP}" "yes" \
          "$(yes_no grep -q "\.${APP}/index.js\$" <<<"${contents}")"
    check "systemd unit"         "yes" \
          "$(yes_no grep -q 'zigbee2mqtt\.service$' <<<"${contents}")"
    # The repository of zigbee2mqtt itself, which fpm is told to exclude. Files like .github or
    # .gitattributes inside dependencies are upstream's own and only counted
    check "no repository data"   "0"   "$(grep -c '/\.git/' <<<"${contents}")"
    info  "upstream .github and .gitattributes inside dependencies" \
          "$(grep -c '/\.git[a-z]' <<<"${contents}") files"
}

# The runtime configuration belongs to the controller, not to the package: as a conffile it made
# dpkg ask whether to replace a file zigbee2mqtt rewrites itself, and "replace" wiped the network
test_config_is_not_packaged() {
    contents=$(deb_contents)
    check "no conffiles declared" "" \
          "$(dpkg-deb -I "${DEB}" conffiles 2>/dev/null | tr -d '[:space:]')"
    check "the runtime configuration is not in the package" "0" \
          "$(grep -c '/zigbee2mqtt/data/configuration\.yaml$' <<<"${contents}")"
    check "the template is"                 "yes" \
          "$(yes_no grep -q '/usr/share/zigbee2mqtt/configuration\.default\.yaml$' <<<"${contents}")"
    check "setup-z2m-config.sh is"              "yes" \
          "$(yes_no grep -q '/usr/lib/zigbee2mqtt/setup-z2m-config\.sh$' <<<"${contents}")"
    check "setup-z2m-config.sh is executable"   "yes" \
          "$(yes_no grep -qE '^-rwx.*setup-z2m-config\.sh$' <<<"${contents}")"
}

test_dependencies_resolvable() {
    plan=$(apt-get install -s "${DEB}" 2>&1)
    grep -E '^(Inst|Remv) ' <<<"${plan}" | sed 's/^/      /'
    check "apt can satisfy the dependencies here" "0" "$(grep -c '^E:' <<<"${plan}")"
}

### the installed package

test_installed_version() {
    check "installed version" "$(deb_field Version)" "$(dpkg-query -W -f='${Version}' zigbee2mqtt 2>/dev/null)"
}

# fpm writes md5sums, so dpkg can tell whether the files on disk are the ones from the package
test_files_intact() {
    rc=0
    listed=$(dpkg -V zigbee2mqtt 2>&1) || rc=$?
    [ -z "${listed}" ] || sed 's/^/        /' <<<"${listed}"
    check "files intact" "0" "${rc}"
}

# git describe can name a version the tree does not carry, and fpm would package it anyway
test_version_matches_sources() {
    in_sources=$(node -p "require('${APP}/package.json').version")
    check "the package version starts with the version in package.json" "yes" \
          "$(yes_no grep -q "^${in_sources}" <<<"$(deb_field Version)")"
}

# Their own FIXME in the Jenkinsfile: duplicated pnpm packages once doubled the size of the package
test_size_within_bounds() {
    bytes=$(stat -c %s "${DEB}")
    check "package size within 8..40 MB" "yes" \
          "$(yes_no test "${bytes}" -ge 8000000 -a "${bytes}" -le 40000000)"
    info  "package size" "$(( bytes / 1048576 )) MB, installed $(( $(deb_field Installed-Size) / 1024 )) MB"
}

test_service_unit_installed() {
    check "systemd unit in place" "yes" \
          "$(yes_no test -f /lib/systemd/system/zigbee2mqtt.service)"
}

# Nothing ships the file, so the install has to create it from the template
test_config_created_on_install() {
    config=${APP}/data/configuration.yaml
    template=/usr/share/zigbee2mqtt/configuration.default.yaml
    check "the configuration is created on install" "yes" "$(yes_no test -e "${config}")"
    [ -e "${config}" ] || return 0
    check "it matches the template" "yes" \
          "$(yes_no cmp -s "${config}" "${template}")"
}

### the application itself

# The one check that covers the whole tree: a runtime dependency dropped by `pnpm prune --prod`,
# a half-built dist or an API the Node.js of this build does not have show up here and nowhere else
test_application_starts() {
    need_command node || return 0
    log=$( cd "${APP}" && timeout 120 node index.js 2>&1 | head -40 )
    check "zigbee2mqtt gets to its own logging" "yes" \
          "$(yes_no grep -q 'Logging to console' <<<"${log}")"
    info  "first line of its log" "$(grep -m1 'z2m:' <<<"${log}" | cut -c1-100)"
}

### the native modules, on the Node.js of this rootfs

test_node_abi() {
    need_command node || return 0
    info "node in this rootfs" \
         "$(node -p 'process.version + ", NODE_MODULE_VERSION " + process.versions.modules')"
}

# unix-dgram is built from source against the ABI of the Node.js used here, and winston-syslog
# loads it on the first log line. A module for another major stops zigbee2mqtt at start
test_unix_dgram_loads() {
    need_command node || return 0
    check "unix-dgram loads the way winston-syslog loads it" "ok" \
          "$(module_loads 'const require_ = require("module").createRequire(require.resolve("winston-syslog"));
                     require_("unix-dgram");
                     console.log("ok")')"
}

# This one comes as a prebuild, so the check is that the prebuild for this architecture is in place
test_serialport_binding_loads() {
    need_command node || return 0
    check "serialport bindings load" "ok" \
          "$(module_loads 'const require_ = require("module").createRequire(require.resolve("zigbee-herdsman"));
                     require_("@serialport/bindings-cpp");
                     console.log("ok")')"
}

### the suites, in the order they run

SUITE_DEB="test_control_fields
           test_depends_on_expected_node
           test_contents
           test_config_is_not_packaged
           test_dependencies_resolvable"

SUITE_INSTALLED="test_installed_version
                 test_files_intact
                 test_version_matches_sources
                 test_size_within_bounds
                 test_service_unit_installed
                 test_config_created_on_install"

SUITE_APPLICATION="test_application_starts"

SUITE_MODULES="test_node_abi
               test_unix_dgram_loads
               test_serialport_binding_loads"

ALL_SUITES="${SUITE_DEB} ${SUITE_INSTALLED} ${SUITE_APPLICATION} ${SUITE_MODULES}"

run_suite() {
    for CURRENT in $1; do "${CURRENT}"; done
}

# A test in no suite would never run and nothing in the counts would show it
verify_suites() {
    listed=$(printf '%s\n' ${ALL_SUITES} | sort)
    defined=$(compgen -A function | grep '^test_' | sort)
    forgotten=$(comm -13 <(echo "${listed}") <(echo "${defined}"))
    unknown=$(comm -23 <(echo "${listed}") <(echo "${defined}"))
    [ -z "${forgotten}" ] || { echo "test functions in no suite: $(echo ${forgotten})" >&2; exit 2; }
    [ -z "${unknown}" ]   || { echo "suites name what is not defined: $(echo ${unknown})" >&2; exit 2; }
}

### main

main() {
    PASSED=0 FAILED=0 SKIPPED=0 CURRENT=''
    parse_arguments "$@"
    verify_suites
    echo "checking $(basename "${DEB}") against Node.js ${BUILD_AND_REQUIRE_NODEJS}"

    # Every wbdev call starts a fresh container, so the package lists here are the ones baked into
    # the image: they know nothing about the Node.js this package requires, and without an update
    # apt calls that dependency uninstallable. The repositories themselves, testing sets included,
    # are written into the rootfs by wbdev before this script runs
    apt-get update
    echo "Node.js available for the install:"
    apt-cache policy nodejs

    section "the .deb file";                   run_suite "${SUITE_DEB}"
    section "install";                         install_package
    section "the installed package";           run_suite "${SUITE_INSTALLED}"
    section "native modules on this Node.js";  run_suite "${SUITE_MODULES}"
    section "the application";                 run_suite "${SUITE_APPLICATION}"

    echo
    echo "=== ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped ==="
    [ "${FAILED}" -eq 0 ]
}

main "$@"
