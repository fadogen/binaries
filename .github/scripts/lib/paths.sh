#!/usr/bin/env bash
# Naming rules for the build tree.

[[ -n "${BASH_VERSION:-}" ]] || {
    echo "[paths] this library requires bash, not ${0##*/}" >&2
    return 1 2>/dev/null || exit 1
}

# Directory a package's sources are extracted into.
#
# The @ of a versioned recipe cannot appear in the path: GNU ar reads a leading
# @ as a response file, so it truncates /…/src/redis@8/… at the @ and fails with
# "Syntax error in archive script". RediSearch hits this when archiving its
# static library, which is why redis built on macOS, whose BSD ar has no such
# syntax, and not on Linux.
# Usage: source_dir_name <package-name>
source_dir_name() {
    printf '%s\n' "${1//@/-}"
}
