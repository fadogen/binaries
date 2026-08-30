#!/usr/bin/env bats
#
# The build matrix is what actually reaches the runners, so it is checked
# against the recipes on disk rather than against an intermediate.

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    source "${LIB_DIR}/recipe.sh"
    MANAGER="${SCRIPTS_DIR}/services-metadata-manager.sh"
}

teardown() {
    teardown_tmpdir
}

@test "the build matrix carries the version each recipe declares" {
    cd "$TEST_TMP" || return 1
    export GITHUB_OUTPUT="${TEST_TMP}/outputs"
    export FILTER_OS="darwin"

    run --separate-stderr "$MANAGER" check-versions
    [ "$status" -eq 0 ]

    local matrix
    matrix="$(grep '^build-matrix=' "$GITHUB_OUTPUT" | cut -d= -f2-)"

    local expected
    expected="$(recipe_field "${RECIPES_DIR}/mysql@9.sh" PACKAGE_VERSION)"
    [ -n "$expected" ]
    [ "$(jq -r --arg v "$expected" '[.include[] | select(.service == "mysql" and .major == "9" and .version == $v)] | length' <<<"$matrix")" -eq 2 ]
    [ "$(jq -r '[.include[] | select(.service == "mysql" and .major == "9")] | first | .recipe' <<<"$matrix")" = "mysql@9" ]
}
