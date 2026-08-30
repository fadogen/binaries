#!/usr/bin/env bats
#
# The bridge between the supported version lines and the recipes on disk.

bats_require_minimum_version 1.5.0

load helper

setup() {
    source "${REPO_ROOT}/.github/config/services-config.sh"
}

@test "every supported service major resolves to a recipe that exists" {
    local service major recipe missing=()

    for service in $AVAILABLE_SERVICES; do
        for major in $(get_supported_versions "$service"); do
            if ! recipe="$(get_recipe_for_service_major "$service" "$major")"; then
                missing+=("${service}@${major}: no recipe")
                continue
            fi
            [[ -f "${RECIPES_DIR}/${recipe}.sh" ]] || missing+=("${service}@${major} -> ${recipe}.sh (absent)")
        done
    done

    [ "${#missing[@]}" -eq 0 ] || {
        printf 'unresolved service majors: %s\n' "${missing[*]}" >&2
        false
    }
}

@test "a service major resolves to the recipe tracking that very line" {
    [ "$(get_recipe_for_service_major mysql 9)" = "mysql@9" ]
    [ "$(get_recipe_for_service_major mariadb 12)" = "mariadb@12" ]
    [ "$(get_recipe_for_service_major postgresql 18)" = "postgresql@18" ]
    [ "$(get_recipe_for_service_major valkey 9)" = "valkey" ]
    [ "$(get_recipe_for_service_major redis 8)" = "redis@8" ]
}
