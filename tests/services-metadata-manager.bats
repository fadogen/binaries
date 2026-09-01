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

@test "a service is rebuilt when a dependency moved, though its own version did not" {
    cd "$TEST_TMP" || return 1
    export GITHUB_OUTPUT="${TEST_TMP}/outputs"
    export FILTER_OS="darwin"

    # Metadata that already carries the current redis version, so only the
    # dependency fingerprint can justify a rebuild.
    local version
    version="$(recipe_field "${RECIPES_DIR}/redis@8.sh" PACKAGE_VERSION)"
    for arch in arm64 x86_64; do
        jq -n --arg v "$version" '{redis: {"8": {latest: $v, sha256: "x", filename: "f", deps: "stale-fingerprint"}}}' \
            > "metadata-services-darwin-${arch}.json"
    done

    run --separate-stderr "$MANAGER" check-versions
    [ "$status" -eq 0 ]

    local matrix
    matrix="$(grep '^build-matrix=' "$GITHUB_OUTPUT" | cut -d= -f2-)"
    [ "$(jq -r '[.include[] | select(.service == "redis")] | length' <<<"$matrix")" -eq 2 ]
}

@test "update-metadata records the dependency fingerprint, so the rebuild is not endless" {
    cd "$TEST_TMP" || return 1
    echo '{}' > metadata-services-darwin-arm64.json

    local version
    version="$(recipe_field "${RECIPES_DIR}/redis@8.sh" PACKAGE_VERSION)"
    printf 'redis,%s,8,abc,redis-%s-darwin-arm64.tar.gz\n' "$version" "$version" \
        | "$MANAGER" update-metadata darwin arm64 2>/dev/null

    source "${LIB_DIR}/recipe.sh"
    RECIPES_DIR="${RECIPES_DIR}" run recipe_dependency_fingerprint "redis@8" darwin
    [ "$(jq -r '.redis."8".deps' metadata-services-darwin-arm64.json)" = "$output" ]
}

@test "a Windows entry ignores the dependency fingerprint, its bundle embedding none" {
    cd "$TEST_TMP" || return 1
    export GITHUB_OUTPUT="${TEST_TMP}/outputs"
    export FILTER_OS="windows"

    local version
    version="$(recipe_field "${RECIPES_DIR}/redis@8.sh" PACKAGE_VERSION)"
    jq -n --arg v "$version" '{redis: {"8": {latest: $v, sha256: "x", filename: "f"}}}' \
        > "metadata-services-windows-x86_64.json"

    run --separate-stderr "$MANAGER" check-versions
    [ "$status" -eq 0 ]

    # Windows repackages upstream binaries: no recipe of ours ships inside.
    local matrix
    matrix="$(grep '^windows-matrix=' "$GITHUB_OUTPUT" | cut -d= -f2-)"
    [ "$(jq -r '[.include[] | select(.service == "redis")] | length' <<<"$matrix")" -eq 0 ]
}

@test "refresh-fingerprints rewrites the fingerprints without touching anything else" {
    cd "$TEST_TMP" || return 1

    jq -n '{redis: {"8": {latest: "8.10.1", sha256: "abc", filename: "f.tar.gz", deps: "computed-by-an-older-method"}}}' \
        > metadata-services-darwin-arm64.json

    run --separate-stderr "$MANAGER" refresh-fingerprints darwin arm64
    [ "$status" -eq 0 ]

    source "${LIB_DIR}/recipe.sh"
    RECIPES_DIR="${RECIPES_DIR}" run recipe_dependency_fingerprint "redis@8" darwin
    [ "$(jq -r '.redis."8".deps' metadata-services-darwin-arm64.json)" = "$output" ]

    # The published artefact is untouched: only the fingerprint is restated.
    [ "$(jq -r '.redis."8".latest' metadata-services-darwin-arm64.json)" = "8.10.1" ]
    [ "$(jq -r '.redis."8".sha256' metadata-services-darwin-arm64.json)" = "abc" ]
    [ "$(jq -r '.redis."8".filename' metadata-services-darwin-arm64.json)" = "f.tar.gz" ]
}
