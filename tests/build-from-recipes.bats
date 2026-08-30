#!/usr/bin/env bats
#
# The build tree's own layout, which some toolchains are picky about.

bats_require_minimum_version 1.5.0

load helper

setup() {
    source "${SCRIPTS_DIR}/lib/paths.sh"
}

@test "a source directory never carries an @, which GNU ar reads as a response file" {
    # `ar` truncates /path/to/redis@8/... at the @ and treats the rest as an
    # archive script, so RediSearch cannot build its static library on Linux.
    [ "$(source_dir_name "redis@8")" = "redis-8" ]
    [ "$(source_dir_name "mysql@9")" = "mysql-9" ]
    [ "$(source_dir_name "zlib")" = "zlib" ]
}
