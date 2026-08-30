#!/usr/bin/env bats
#
# The dependency lister feeds the order recipes are written in, so the contract
# under test is the topological order it prints.

bats_require_minimum_version 1.5.0

load helper

setup() {
    export BREW_API_BASE="file://${FIXTURES_DIR}/api-deps"
    DEPS="${SCRIPTS_DIR}/get-brew-dependencies.sh"
}

@test "dependencies come out before the package that needs them" {
    run --separate-stderr "$DEPS" alpha

    [ "$status" -eq 0 ]
    # gamma <- beta <- alpha, with the build dependency in between.
    [ "${lines[0]}" = "gamma" ]
    [ "${lines[1]}" = "beta" ]
    [ "${lines[2]}" = "tooling" ]
    [ "${lines[3]}" = "alpha" ]
}
