#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    source "${LIB_DIR}/recipe.sh"
}

teardown() {
    teardown_tmpdir
}

@test "recipe_field reads a declared metadata field" {
    local file
    file="$(make_recipe "redis@8" "8.6.3" "abc123")"

    run recipe_field "$file" PACKAGE_VERSION

    [ "$status" -eq 0 ]
    [ "$output" = "8.6.3" ]
}

@test "recipe_field fails loudly when the recipe does not exist" {
    run recipe_field "${TEST_TMP}/absent.sh" PACKAGE_VERSION

    [ "$status" -ne 0 ]
    [[ "$output" == *"recipe not found"* ]]
}

@test "recipe_set_field updates a value and leaves the rest of the recipe intact" {
    local file
    file="$(make_recipe "redis@8" "8.6.3" "abc123")"

    run recipe_set_field "$file" PACKAGE_VERSION "8.10.1"
    [ "$status" -eq 0 ]

    [ "$(recipe_field "$file" PACKAGE_VERSION)" = "8.10.1" ]
    # The URL template still resolves, against the new version.
    [ "$(recipe_field "$file" PACKAGE_URL)" = "https://example.test/redis@8-8.10.1.tar.gz" ]
    # Untouched fields survive.
    [ "$(recipe_field "$file" PACKAGE_SHA256)" = "abc123" ]
    # The build function survives.
    grep -q "^build() {" "$file"
}

@test "recipe_set_field refuses to silently drop an unknown field" {
    local file
    file="$(make_recipe "redis@8" "8.6.3")"

    run recipe_set_field "$file" PACKAGE_NSPR_VERSION "4.39"

    [ "$status" -ne 0 ]
    [[ "$output" == *"no such field"* ]]
}

@test "recipe_set_field on a real recipe changes exactly one line and keeps the file executable" {
    cp "${RECIPES_DIR}/openssl@3.sh" "${TEST_TMP}/openssl@3.sh"
    local file="${TEST_TMP}/openssl@3.sh"

    recipe_set_field "$file" PACKAGE_VERSION "3.99.9"

    [ -x "$file" ]
    run diff "${RECIPES_DIR}/openssl@3.sh" "$file"
    [ "$status" -eq 1 ]
    # A single-line change: one "<", one ">", one "Nc N" header.
    [ "$(printf '%s\n' "$output" | grep -c '^<')" -eq 1 ]
    [ "$(printf '%s\n' "$output" | grep -c '^>')" -eq 1 ]
}

@test "recipe_set_array rewrites a checksum list of a different length" {
    cp "${RECIPES_DIR}/readline.sh" "${TEST_TMP}/readline.sh"
    local file="${TEST_TMP}/readline.sh"

    run recipe_set_array "$file" PATCH_CHECKSUMS aaa bbb ccc ddd
    [ "$status" -eq 0 ]

    # Read back through bash itself: the file must still be valid shell.
    run bash -c 'source "$1"; printf "%s\n" "${PATCH_CHECKSUMS[@]}"' _ "$file"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "aaa" ]
    [ "${lines[3]}" = "ddd" ]
    [ "${#lines[@]}" -eq 4 ]

    # The build function is untouched.
    grep -q 'Applying patches' "$file"
}

@test "the recipe library refuses to run under a shell that cannot support it" {
    command -v zsh >/dev/null || skip "zsh not installed"

    run zsh -c "source '${LIB_DIR}/recipe.sh'"

    [ "$status" -ne 0 ]
    [[ "$output" == *"requires bash"* ]]
}
