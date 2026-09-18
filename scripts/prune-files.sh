#!/bin/bash
# Removes the files of the built application that nobody can use on a controller.
# Usage: prune-files.sh [--check] <tree>
#   --check  remove nothing, only say whether the tree is already clean
#   tree     the built zigbee2mqtt: the directory with dist, node_modules and package.json
# Runs on the build agent, never on a controller.
# Exit: 0 done, 1 no such tree or a failed check, 2 usage
#
# What is removed, what is kept and why: README.md, "Files the package does not carry"

set -euo pipefail

usage() { sed -n '2,7p' "$0" >&2; exit 2; }

# Every file this script owns, one path per line
files_to_remove() {
    find "${TREE}/test" -type f 2>/dev/null || true
    find "${TREE}" -maxdepth 1 -type f -name 'tsconfig.tsbuildinfo' 2>/dev/null || true
}

# group <what> <find arguments>: how many files and how big, then remove them
group() {
    local what=$1
    shift
    local list
    list=$(find "$@" -type f 2>/dev/null || true)
    if [ -z "${list}" ]; then
        printf '  %-42s %5s\n' "${what}" "none"
        return 0
    fi
    printf '  %-42s %5d files %7d KB\n' "${what}" \
           "$(echo "${list}" | wc -l)" \
           "$(echo "${list}" | tr '\n' '\0' | du -ck --files0-from=- | tail -1 | cut -f1)"
    echo "${list}" | tr '\n' '\0' | xargs -0 rm -f
}

prune_tree() {
    echo "=== removing files nobody can use on a controller ==="
    group "the test suite of the application" "${TREE}/test"
    group "the incremental build state"       "${TREE}" -maxdepth 1 -name 'tsconfig.tsbuildinfo'
    rm -rf "${TREE:?}/test"
    echo "=== the tree is now $(find "${TREE}" -type f | wc -l) files, $(du -sk "${TREE}" | cut -f1) KB ==="
}

check_tree() {
    local left
    left=$(files_to_remove | wc -l)
    if [ "${left}" -ne 0 ]; then
        echo "${TREE} still carries ${left} files nobody can use on a controller." >&2
        echo "The build removes them in a step of its own, before the package is packed:" >&2
        echo "  bash scripts/prune-files.sh ${TREE}" >&2
        exit 1
    fi
    echo "checked: ${TREE} carries no files of that kind"
}

main() {
    MODE=prune
    if [ "${1:-}" = "--check" ]; then
        MODE=check
        shift
    fi
    [ $# -eq 1 ] || usage
    TREE=$1
    [ -d "${TREE}" ] || { echo "prune-files.sh: no such tree: ${TREE}" >&2; exit 1; }

    case "${MODE}" in
        check) check_tree ;;
        prune) prune_tree ;;
    esac
}

main "$@"
