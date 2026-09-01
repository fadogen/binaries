#!/usr/bin/env bats
#
# A bundle embeds its dependencies, so a service must be rebuilt when one of
# them moves, not only when its own version does.

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    source "${LIB_DIR}/recipe.sh"
    export RECIPES_DIR="${TEST_TMP}/recipes"
    mkdir -p "$RECIPES_DIR"
}

teardown() {
    teardown_tmpdir
}

# A recipe declaring runtime dependencies.
given_recipe_with_deps() {
    local name="$1" version="$2"
    shift 2
    local file="${RECIPES_DIR}/${name}.sh"
    {
        printf '#!/bin/bash\nexport PACKAGE_NAME="%s"\nexport PACKAGE_VERSION="%s"\n' "$name" "$version"
        printf 'export DEPENDENCIES=(\n'
        printf '    "%s"\n' "$@"
        printf ')\n'
    } > "$file"
}

@test "the fingerprint changes when a dependency moves, though the service did not" {
    given_recipe_with_deps "redis@8" "8.10.1" "openssl@3"
    given_recipe_with_deps "openssl@3" "3.6.3"

    local before
    before="$(recipe_dependency_fingerprint "redis@8")"

    given_recipe_with_deps "openssl@3" "3.6.4"

    [ -n "$before" ]
    [ "$(recipe_dependency_fingerprint "redis@8")" != "$before" ]
}

@test "a transitive dependency counts, being embedded in the bundle too" {
    given_recipe_with_deps "redis@8" "8.10.1" "openssl@3"
    given_recipe_with_deps "openssl@3" "3.6.4" "ca-certificates"
    given_recipe_with_deps "ca-certificates" "2026-08-13"

    local before
    before="$(recipe_dependency_fingerprint "redis@8")"

    # Two levels down, and still part of what ships.
    given_recipe_with_deps "ca-certificates" "2026-09-01"

    [ "$(recipe_dependency_fingerprint "redis@8")" != "$before" ]
}

@test "the fingerprint is stable when nothing moves" {
    given_recipe_with_deps "redis@8" "8.10.1" "openssl@3"
    given_recipe_with_deps "openssl@3" "3.6.4"

    [ "$(recipe_dependency_fingerprint "redis@8")" = "$(recipe_dependency_fingerprint "redis@8")" ]
}

@test "the fingerprint is computed for a target OS, not for the machine running it" {
    # update-metadata runs on Linux for every platform, so the OS must be an
    # argument rather than whatever uname says.
    cat > "${RECIPES_DIR}/mysql@9.sh" <<'RECIPE'
#!/bin/bash
export PACKAGE_NAME="mysql@9"
export PACKAGE_VERSION="9.7.2"
export DEPENDENCIES=("openssl@3")
export DEPENDENCIES_LINUX=("libtirpc")
RECIPE
    printf '#!/bin/bash\nexport PACKAGE_NAME="openssl@3"\nexport PACKAGE_VERSION="3.6.4"\n' > "${RECIPES_DIR}/openssl@3.sh"
    printf '#!/bin/bash\nexport PACKAGE_NAME="libtirpc"\nexport PACKAGE_VERSION="1.3.7"\n' > "${RECIPES_DIR}/libtirpc.sh"

    [ "$(recipe_dependency_fingerprint "mysql@9" linux)" != "$(recipe_dependency_fingerprint "mysql@9" darwin)" ]
}
