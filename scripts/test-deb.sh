#!/bin/bash
# Checks the built zigbee2mqtt package before it goes anywhere: control fields, contents, and that
# the native modules inside it load on the Node.js the package requires.
# Usage: test-deb.sh <result dir>
# Env:   BUILD_AND_REQUIRE_NODEJS, the major the package has to depend on
# Exit:  0 all checks passed, 1 a check failed (the summary names it), 2 usage or a broken suite list
#
# Runs inside "wbdev chroot" right after build.sh, in a rootfs of its own: apt installs the
# Node.js again here, by the dependency of the package, so it is the same version and not the
# same files the build used.
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
        # The names are repeated at the end: in Jenkins the tail of the log is what one sees first
        FAILED_NAMES="${FAILED_NAMES}${FAILED_NAMES:+, }$1"
    fi
}
skip()    { SKIPPED=$((SKIPPED + 1)); echo "skip  $1"; }
info()    { echo "info  $1: $2"; }
section() { echo; echo "=== $* ==="; }

# run_section <title> <suite>: the tests of one suite, with the time they took
run_section() {
    section "$1"
    started=$(date +%s)
    for CURRENT in $2; do "${CURRENT}"; done
    echo "      ${1} took $(( $(date +%s) - started ))s"
}

### tools

yes_no()       { if "$@"; then echo yes; else echo no; fi; }
# The newest released version of a package here: the regular repositories only. A testing set
# publishes experimental.* suites, and the packages there are builds of a branch, not something a
# controller would have, so they are no fixture for an upgrade
released_version_of() {
    apt-cache madison "$1" 2>/dev/null |
        grep -v 'experimental\.' |
        awk -F'|' 'NR == 1 { gsub(/ /, "", $2); print $2 }'
}

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

# The package that dependency is about: nodejs, or nodejs-16 for that old release
expected_package() { expected_dependency | sed 's/ .*//'; }

# apt_errors <log>: the lines that say what went wrong, or the tail when there are none
apt_errors() {
    errors=$(grep -E '^(E:|dpkg: )' "$1" | head -10)
    if [ -n "${errors}" ]; then
        sed 's/^/        /' <<<"${errors}"
    else
        tail -10 "$1" | sed 's/^/        /'
    fi
}

need_command() {
    command -v "$1" > /dev/null && return 0
    skip "${CURRENT}: no $1 here"
    return 1
}

# Writes /usr/sbin/policy-rc.d, the file a maintainer script asks before it starts a service:
# exit code 101 there means "not allowed", and no file at all means "allowed". Nothing has to run
# in this rootfs, it has no systemd and the tests read files
# copies_in <directory>: how many copies of the data are kept there
copies_in() {
    find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
}

forbid_service_start() {
    cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 0755 /usr/sbin/policy-rc.d
}

# Takes that file away, so services may start again
allow_service_start() { rm -f /usr/sbin/policy-rc.d; }

# The package is installed for real, as on a controller. In this rootfs there is no systemd, and
# the maintainer script of a fresh install tolerates that: every systemctl call ends with || true
install_package() {
    forbid_service_start
    apt-get install -y "${DEB}" || { echo "FAIL  the package does not install, nothing else can be checked"; exit 1; }
    allow_service_start
}

### the package itself

test_control_fields() {
    check "package name" "zigbee2mqtt" "$(deb_field Package | sed 's/-[0-9].*//')"
    check "architecture" "${ARCH}"       "$(deb_field Architecture)"
    info  "version"      "$(deb_field Version)"
}

# The Jenkinsfile writes the version of a branch build into debian/changelog, and fpm packs that
# file: the entry on top has to name the version the package carries, or one of the two is stale.
# fpm names it changelog.gz, while the Debian policy name for a non-native package is
# changelog.Debian.gz, so the pattern covers both
test_changelog_matches_version() {
    top=$(dpkg-deb --fsys-tarfile "${DEB}" |
          tar -xOf - --wildcards "*usr/share/doc/$(deb_field Package)/changelog*.gz" 2>/dev/null |
          gzip -dc 2>/dev/null | head -n 1)
    check "the version on top of the packaged changelog" "$(deb_field Version)" \
          "$(sed -n 's/^[^ ]* (\([^)]*\)).*/\1/p' <<<"${top}")"
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

# TEMPORARY, goes away with package/backup-z2m-data.sh.
# Checks:
#   - an install over an existing installation leaves one more copy, with the configuration in it
#   - the next install leaves one more again: earlier copies are not rotated away
# Does not check:
#   - a first install: there is no data to copy then
test_data_copied_to_var_backups() {
    backups=/var/backups/zigbee2mqtt
    before=$(copies_in "${backups}")
    forbid_service_start
    mkdir -p "${APP}/data"
    echo "wb-backup-marker" >> "${APP}/data/configuration.yaml"

    apt-get install -y --reinstall "${DEB}" > /tmp/backup-install.log 2>&1 ||
        apt_errors /tmp/backup-install.log
    check "an install leaves one more copy" "$((before + 1))" "$(copies_in "${backups}")"
    check "the configuration is in it"      "yes" \
          "$(yes_no grep -rq 'wb-backup-marker' "${backups}")"
    # The copy has to say what it was made before, with the version dpkg was replacing
    check "the copy names the old version" "yes" \
          "$(yes_no grep -rq "old version: $(deb_field Version)" "${backups}")"

    apt-get install -y --reinstall "${DEB}" > /tmp/backup-install.log 2>&1 ||
        apt_errors /tmp/backup-install.log
    check "the next install adds one more"  "$((before + 2))" "$(copies_in "${backups}")"

    # Two more, so that more copies than the limit have been made
    apt-get install -y --reinstall "${DEB}" > /tmp/backup-install.log 2>&1 ||
        apt_errors /tmp/backup-install.log
    apt-get install -y --reinstall "${DEB}" > /tmp/backup-install.log 2>&1 ||
        apt_errors /tmp/backup-install.log
    check "only three copies are kept"      "3"   "$(copies_in "${backups}")"
    check "the newest copy is the last one" "yes" \
          "$(yes_no grep -rq 'wb-backup-marker' "${backups}")"

    sed -i '/wb-backup-marker/d' "${APP}/data/configuration.yaml"
    allow_service_start
}

# The result of the cleanup step, checked in the package itself.
# Checks:
#   - no test suite, no state of an incremental TypeScript compile
# Does not check:
#   - source maps, type definitions and markdown texts: they stay for now, and how many of them
#     the package carries is printed below
test_developer_files_not_packaged() {
    contents=$(deb_contents)
    check "no test suite"            "0" "$(grep -c "\.${APP}/test/" <<<"${contents}")"
    check "no incremental build state" "0" \
          "$(grep -c 'tsconfig\.tsbuildinfo$' <<<"${contents}")"
    info  "source maps kept"         "$(grep -c '\.map$' <<<"${contents}") files"
    info  "type definitions kept"    "$(grep -c '\.d\.ts$' <<<"${contents}") files"
    info  "markdown kept"            "$(grep -c '\.md$' <<<"${contents}") files"
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

# dpkg_path_globs exclude|include: the globs of the dpkg configuration, one per line. A rootfs
# tells dpkg what to leave out of every package ("exclude") and what to keep anyway ("include")
dpkg_path_globs() {
    cat /etc/dpkg/dpkg.cfg /etc/dpkg/dpkg.cfg.d/* 2>/dev/null |
        sed -n "s/^[[:space:]]*path-$1[[:space:]]*=\{0,1\}[[:space:]]*//p"
}

# path_matches <path> <globs>: true when the path fits one of the globs
path_matches() {
    for glob in $2; do
        case "$1" in ${glob}) return 0 ;; esac
    done
    return 1
}

# verify_lines_about_kept_files <package>: the lines of "dpkg -V" about files this rootfs was
# allowed to unpack
verify_lines_about_kept_files() {
    excluded=$(dpkg_path_globs exclude)
    included=$(dpkg_path_globs include)
    # The globs are here to be matched, not to be expanded against this filesystem
    set -f
    dpkg -V "$1" 2>&1 | while read -r line; do
        path=${line##* }
        if path_matches "${path}" "${included}" || ! path_matches "${path}" "${excluded}"; then
            echo "${line}"
        fi
    done
    set +f
}

# Asks dpkg whether the files on disk are the ones from the package: fpm writes md5sums for that.
# Checks:
#   - every line "dpkg -V" prints, because a missing file still leaves its exit code at zero
# Does not check:
#   - manuals, documentation and most translations: the rootfs of a controller and the rootfs of
#     this build both tell dpkg to leave them out of every package ("path-exclude"), and dpkg then
#     calls them missing. What such a rule lets through ("path-include") is checked
#   - "data/configuration.yaml", which the package no longer ships: it belongs to the controller
test_files_intact() {
    excluded=$(dpkg_path_globs exclude | tr '\n' ' ')
    included=$(dpkg_path_globs include | tr '\n' ' ')
    [ -z "${excluded}" ] || info "paths this rootfs does not unpack" "${excluded}"
    [ -z "${included}" ] || info "paths it keeps anyway"           "${included}"
    listed=$(verify_lines_about_kept_files zigbee2mqtt)
    [ -z "${listed}" ] || sed 's/^/        /' <<<"${listed}"
    check "files dpkg finds changed or missing" "0" "$(grep -c '[^[:space:]]' <<<"${listed}")"
}

# debian/changelog can name a version the tree does not carry, and fpm would package it anyway
test_version_matches_sources() {
    need_command node || return 0
    in_sources=$(node -p "require('${APP}/package.json').version")
    # An empty value would turn the comparison below into a match against any version
    check "the version in package.json" "yes" "$(yes_no test -n "${in_sources}")"
    [ -n "${in_sources}" ] || return 0
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

# Starts the application from the package and waits for its first log line.
# Checks:
#   - a module that "pnpm prune --prod" removed, but the code still needs it
#   - files that are missing in "dist/", because "pnpm run build" did not finish
#   - an API that this version of Node.js does not have
# Does not check:
#   - syslog: the configuration in the package writes logs to the console and to a file, so
#     "winston-syslog" and its "unix-dgram" are not loaded, and a broken "unix-dgram" would not fail
#     this test. That module is checked in test_unix_dgram_loads
test_smoke_start() {
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

# Loads "unix-dgram" the way "winston-syslog" loads it: the module is built from source against the
# ABI of one Node.js major, and a module for another major stops zigbee2mqtt at the first log line.
# Checks:
#   - the module built here loads on the Node.js this package requires
# Does not check:
#   - logging to syslog itself, which needs a running service and a syslog socket
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

### the upgrade from the repositories

# Installs the released version, marks its configuration and upgrades to the package built here.
# The configuration has to survive: this package does not ship it, so dpkg has nothing to replace,
# and the maintainer scripts must not touch a file that is already there.
# Checks:
#   - the upgrade really happens: the version before is the released one, the version after is the
#     one from this build
#   - the configuration file is the same after the upgrade, byte for byte
# Does not check:
#   - an upgrade from a version older than the repositories carry
#   - a downgrade to the released version, which does ask about the configuration: the file our
#     package creates belongs to no package, and dpkg has a question about that
test_upgrade_keeps_config() {
    config_path=${APP}/data/configuration.yaml
    version_built_here=$(deb_field Version)

    # What this rootfs has and where from: with a testing set connected there is an experimental.*
    # line here too, and the log has to show which of them the version below came from
    echo "      zigbee2mqtt in the repositories of this rootfs:"
    apt-cache policy zigbee2mqtt 2>/dev/null | sed 's/^/        /'

    version_to_upgrade_from=$(released_version_of zigbee2mqtt)
    if [ -z "${version_to_upgrade_from}" ] || [ "${version_to_upgrade_from}" = "${version_built_here}" ]; then
        skip "${CURRENT}: no released zigbee2mqtt in the repositories of this rootfs"
        return 0
    fi
    info "the version to upgrade from" "${version_to_upgrade_from}"

    forbid_service_start
    # From a rootfs that has neither this package nor the configuration it creates: the released
    # version ships that file as a conffile, and dpkg would stop to ask about a file it does not own
    apt-get purge -y zigbee2mqtt > /tmp/purge.log 2>&1
    rm -f "${config_path}"

    if ! apt-get install -y "zigbee2mqtt=${version_to_upgrade_from}" > /tmp/from-repo.log 2>&1; then
        apt_errors /tmp/from-repo.log
        check "the released version installs" "yes" "no"
        allow_service_start
        return 0
    fi
    check "installed before the upgrade" "${version_to_upgrade_from}" \
          "$(dpkg-query -W -f='${Version}' zigbee2mqtt)"

    printf '\n# wb-upgrade-marker\n' >> "${config_path}"
    cp "${config_path}" "${config_path}.before-upgrade"

    apt-get install -y "${DEB}" > /tmp/upgrade.log 2>&1 || apt_errors /tmp/upgrade.log
    check "installed after the upgrade" "${version_built_here}" \
          "$(dpkg-query -W -f='${Version}' zigbee2mqtt)"
    check "the marker survives the upgrade" "yes" \
          "$(yes_no grep -q 'wb-upgrade-marker' "${config_path}")"
    check "the configuration is the same file" "yes" \
          "$(yes_no cmp -s "${config_path}.before-upgrade" "${config_path}")"
    cmp -s "${config_path}.before-upgrade" "${config_path}" ||
        diff -u "${config_path}.before-upgrade" "${config_path}" | head -20 | sed 's/^/        /'

    rm -f "${config_path}.before-upgrade"
    sed -i '/wb-upgrade-marker/d' "${config_path}"
    allow_service_start
}

### the suites, in the order they run

SUITE_DEB="test_control_fields
           test_changelog_matches_version
           test_depends_on_expected_node
           test_contents
           test_developer_files_not_packaged
           test_config_is_not_packaged
           test_dependencies_resolvable"

SUITE_INSTALLED="test_installed_version
                 test_files_intact
                 test_data_copied_to_var_backups
                 test_version_matches_sources
                 test_size_within_bounds
                 test_service_unit_installed
                 test_config_created_on_install"

SUITE_APPLICATION="test_smoke_start"

SUITE_MODULES="test_node_abi
               test_unix_dgram_loads
               test_serialport_binding_loads"

SUITE_UPGRADE="test_upgrade_keeps_config"

ALL_SUITES="${SUITE_DEB} ${SUITE_INSTALLED} ${SUITE_APPLICATION} ${SUITE_MODULES} ${SUITE_UPGRADE}"

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
    PASSED=0 FAILED=0 SKIPPED=0 CURRENT='' FAILED_NAMES=''
    parse_arguments "$@"
    verify_suites
    echo "checking $(basename "${DEB}") against Node.js ${BUILD_AND_REQUIRE_NODEJS}"

    # Every wbdev call starts a fresh container, so the package lists here are the ones baked into
    # the image: they know nothing about the Node.js this package requires, and without an update
    # apt calls that dependency uninstallable. The repositories themselves, testing sets included,
    # are written into the rootfs by wbdev before this script runs
    apt-get update
    echo "Node.js available for the install:"
    apt-cache policy "$(expected_package)"

    run_section "the .deb file"                  "${SUITE_DEB}"
    section     "install";                       install_package
    run_section "the installed package"          "${SUITE_INSTALLED}"
    run_section "native modules on this Node.js" "${SUITE_MODULES}"
    run_section "the application"                "${SUITE_APPLICATION}"
    # Last: it replaces the installed package twice, and the tests above expect the one built here
    run_section "upgrade from the repositories"  "${SUITE_UPGRADE}"

    echo
    [ -z "${FAILED_NAMES}" ] || echo "=== failed: ${FAILED_NAMES} ==="
    summary="${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
    echo "=== ${summary} ==="
    # The Jenkinsfile puts this line into the description of the build
    echo "${summary}" > "${RESULT_DIR}/test-summary.txt" 2>/dev/null || true
    [ "${FAILED}" -eq 0 ]
}

main "$@"
