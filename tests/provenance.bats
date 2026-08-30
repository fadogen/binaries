#!/usr/bin/env bats
#
# The provenance file is what tells a bundle's recipient where the corresponding
# source lives, which the copyleft licences in these bundles require.

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    source "${LIB_DIR}/recipe.sh"
    source "${LIB_DIR}/provenance.sh"
}

teardown() {
    teardown_tmpdir
}

licensed_recipe() {
    local name="$1" version="$2" license="$3"
    local file
    file="$(make_recipe "$name" "$version" "sha-of-${name}")"
    printf '\nexport PACKAGE_LICENSE="%s"\n' "$license" >> "$file"
    echo "$file"
}

@test "the document names every component with its source and checksum" {
    local redis openssl
    redis="$(licensed_recipe "redis@8" "8.10.1" "AGPL-3.0-only AND MIT")"
    openssl="$(licensed_recipe "openssl@3" "3.6.3" "Apache-2.0")"

    run provenance_document "redis 8.10.1 (darwin/arm64)" "$redis" "$openssl"

    [ "$status" -eq 0 ]
    [[ "$output" == *"redis 8.10.1 (darwin/arm64)"* ]]
    [[ "$output" == *"redis@8"*"8.10.1"* ]]
    [[ "$output" == *"AGPL-3.0-only AND MIT"* ]]
    [[ "$output" == *"https://example.test/redis@8-8.10.1.tar.gz"* ]]
    [[ "$output" == *"sha-of-redis@8"* ]]
    [[ "$output" == *"openssl@3"*"3.6.3"* ]]
    [[ "$output" == *"Apache-2.0"* ]]
}

@test "the document refuses to be written from a recipe it cannot read" {
    local redis
    redis="$(licensed_recipe "redis@8" "8.10.1" "AGPL-3.0-only")"

    # A silently incomplete provenance notice is worse than none: it claims a
    # completeness it does not have.
    run provenance_document "redis 8.10.1" "$redis" "${TEST_TMP}/absent.sh"

    [ "$status" -ne 0 ]
}

@test "provenance_write drops the file into the bundle, and writes nothing on failure" {
    local bundle="${TEST_TMP}/bundle"
    mkdir -p "$bundle"
    local redis
    redis="$(licensed_recipe "redis@8" "8.10.1" "AGPL-3.0-only")"

    run provenance_write "$bundle" "redis 8.10.1 (darwin/arm64)" "$redis"
    [ "$status" -eq 0 ]
    [ -f "${bundle}/PROVENANCE.txt" ]
    grep -q "AGPL-3.0-only" "${bundle}/PROVENANCE.txt"

    rm "${bundle}/PROVENANCE.txt"
    run provenance_write "$bundle" "redis 8.10.1" "${TEST_TMP}/absent.sh"
    [ "$status" -ne 0 ]
    [ ! -f "${bundle}/PROVENANCE.txt" ]
}
