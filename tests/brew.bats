#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    export BREW_API_BASE="file://${FIXTURES_DIR}/api"
    source "${LIB_DIR}/brew.sh"
}

teardown() {
    teardown_tmpdir
}

@test "brew_formula_json returns the formula document" {
    run brew_formula_json redis

    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.versions.stable')" = "8.10.1" ]
}

@test "brew_resolve_formula keeps a versioned formula that already serves the line" {
    run brew_resolve_formula "postgresql@18"

    [ "$status" -eq 0 ]
    [ "$output" = "postgresql@18" ]
}

@test "brew_resolve_formula follows a renamed line, mysql@9 now being served by mysql@9.7" {
    run brew_resolve_formula "mysql@9"

    [ "$status" -eq 0 ]
    [ "$output" = "mysql@9.7" ]
}

@test "brew_resolve_formula prefers the highest version inside the line, redis over redis@8.2" {
    run brew_resolve_formula "redis@8"

    [ "$status" -eq 0 ]
    [ "$output" = "redis" ]
}

@test "brew_resolve_formula picks the base formula when it is the one serving the line" {
    run brew_resolve_formula "mariadb@12"

    [ "$status" -eq 0 ]
    [ "$output" = "mariadb" ]
}

@test "brew_resolve_formula refuses to guess when no formula serves the line" {
    run brew_resolve_formula "mysql@5"

    [ "$status" -ne 0 ]
    [[ "$output" == *"no formula serves line: mysql@5"* ]]
}

@test "brew_source_of exposes the upstream tarball of a formula" {
    run brew_source_of redis

    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.version')" = "8.10.1" ]
    [ "$(printf '%s' "$output" | jq -r '.url')" = "https://download.redis.io/releases/redis-8.10.1.tar.gz" ]
    [ "$(printf '%s' "$output" | jq -r '.sha256')" = "60166c95ab7aedaa9dfe516de685be0a4dd87be95ded59ba429df14c13f1b663" ]
}

@test "brew_source_of carries patch checksums in the order upstream applies them" {
    run brew_source_of readline

    [ "$status" -eq 0 ]
    # readline 8.3.3 is the 8.3 tarball plus three cherry-picked patches.
    [ "$(printf '%s' "$output" | jq -r '.version')" = "8.3.3" ]
    [ "$(printf '%s' "$output" | jq -r '.url')" = "https://ftpmirror.gnu.org/gnu/readline/readline-8.3.tar.gz" ]
    [ "$(printf '%s' "$output" | jq -r '.patches | length')" -eq 3 ]
    [ "$(printf '%s' "$output" | jq -r '.patches[0]')" = "21f0a03106dbe697337cd25c70eb0edbaa2bdb6d595b45f83285cdd35bac84de" ]
    [ "$(printf '%s' "$output" | jq -r '.patches[2]')" = "72dee13601ce38f6746eb15239999a7c56f8e1ff5eb1ec8153a1f213e4acdb29" ]
}

@test "brew_source_of only lists patches a recipe could replay" {
    # Homebrew keeps some patches inside its own tap or inline in the formula.
    # Those carry no URL, so nothing downstream can fetch them.
    run brew_source_of "openssl@3"

    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.patches | length')" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.unreplayable_patches')" -eq 4 ]
}

@test "brew_formula_fingerprint ignores a version bump" {
    export BREW_SOURCE_BASE="file://${FIXTURES_DIR}/formula-source"

    run brew_formula_fingerprint "redis-8.10.0.rb"
    [ "$status" -eq 0 ]
    local before="$output"

    run brew_formula_fingerprint "redis-8.10.1.rb"
    [ "$status" -eq 0 ]
    [ "$output" = "$before" ]
}

@test "brew_formula_fingerprint moves when the build logic does" {
    export BREW_SOURCE_BASE="file://${FIXTURES_DIR}/formula-source"

    run brew_formula_fingerprint "redis-8.10.1.rb"
    local unchanged="$output"

    # Same upstream version, but Homebrew started building the modules.
    run brew_formula_fingerprint "redis-build-modules.rb"
    [ "$status" -eq 0 ]
    [ "$output" != "$unchanged" ]
}
