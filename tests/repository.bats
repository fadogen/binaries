#!/usr/bin/env bats
#
# Checks the repository against the live Homebrew API. Set SKIP_NETWORK_TESTS=1
# to skip when offline.

bats_require_minimum_version 1.5.0

load helper

setup() {
    [[ -n "${SKIP_NETWORK_TESTS:-}" ]] && skip "network tests disabled"
    source "${LIB_DIR}/brew.sh"
}

@test "every recipe tracks a line Homebrew still serves" {
    local file recipe orphans=()

    for file in "${RECIPES_DIR}"/*.sh; do
        recipe="$(basename "$file" .sh)"
        brew_resolve_formula "$recipe" >/dev/null 2>&1 || orphans+=("$recipe")
    done

    # An orphan recipe silently stops receiving updates, which is how a stale
    # binary ships. Re-anchor it on the major line instead of the minor one.
    [ "${#orphans[@]}" -eq 0 ] || {
        printf 'orphan recipes: %s\n' "${orphans[*]}" >&2
        false
    }
}
