#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    export BREW_API_BASE="file://${FIXTURES_DIR}/api"
    export RECIPES_DIR="${TEST_TMP}/recipes"
    mkdir -p "$RECIPES_DIR"
    SYNC="${SCRIPTS_DIR}/sync-upstream.sh"
}

teardown() {
    teardown_tmpdir
}

# Put a recipe under the directory the sync scans. Like the real recipes, its
# URL template mirrors the one the tracked formula uses.
given_recipe() {
    local name="$1" version="$2" sha256="${3:-deadbeef}"
    local url="$4"
    [[ -n "$url" ]] || url='https://download.redis.io/releases/redis-${PACKAGE_VERSION}.tar.gz'
    local file
    file="$(make_recipe "$name" "$version" "$sha256" "$url")"
    mv "$file" "${RECIPES_DIR}/${name}.sh"
}

@test "check reports a recipe left behind by upstream without touching it" {
    given_recipe "redis@8" "8.6.3"

    # The report is stdout; progress goes to stderr.
    run --separate-stderr "$SYNC" check

    [ "$status" -eq 0 ]
    local report="$output"
    [ "$(jq -r '.recipes[0].recipe' <<<"$report")" = "redis@8" ]
    [ "$(jq -r '.recipes[0].formula' <<<"$report")" = "redis" ]
    [ "$(jq -r '.recipes[0].from' <<<"$report")" = "8.6.3" ]
    [ "$(jq -r '.recipes[0].to' <<<"$report")" = "8.10.1" ]
    [ "$(jq -r '.recipes[0].status' <<<"$report")" = "outdated" ]
    # check never writes.
    [ "$(grep -c '8.6.3' "${RECIPES_DIR}/redis@8.sh")" -ge 1 ]
}

@test "apply writes the upstream version and checksum into the recipe" {
    given_recipe "redis@8" "8.6.3" "staleaaaa"

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]
    [ "$(jq -r '.recipes[0].status' <<<"$output")" = "updated" ]

    source "${LIB_DIR}/recipe.sh"
    local file="${RECIPES_DIR}/redis@8.sh"
    [ "$(recipe_field "$file" PACKAGE_VERSION)" = "8.10.1" ]
    [ "$(recipe_field "$file" PACKAGE_SHA256)" = "60166c95ab7aedaa9dfe516de685be0a4dd87be95ded59ba429df14c13f1b663" ]
}

@test "apply syncs the patch checksums a recipe applies on top of the tarball" {
    cp "${REPO_ROOT}/.github/scripts/recipes/readline.sh" "${RECIPES_DIR}/readline.sh"
    source "${LIB_DIR}/recipe.sh"
    # Rewind the recipe to a state with fewer patches than upstream now ships.
    recipe_set_field "${RECIPES_DIR}/readline.sh" PACKAGE_VERSION "8.3.1"
    recipe_set_array "${RECIPES_DIR}/readline.sh" PATCH_CHECKSUMS "old-001"

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]
    [ "$(jq -r '.recipes[0].status' <<<"$output")" = "updated" ]

    run bash -c 'source "$1"; printf "%s\n" "${PATCH_CHECKSUMS[@]}"' _ "${RECIPES_DIR}/readline.sh"
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "21f0a03106dbe697337cd25c70eb0edbaa2bdb6d595b45f83285cdd35bac84de" ]
    [ "${lines[2]}" = "72dee13601ce38f6746eb15239999a7c56f8e1ff5eb1ec8153a1f213e4acdb29" ]
}

@test "apply recomputes the checksum when the recipe builds its own source URL" {
    # This recipe does not download what Homebrew downloads, so the formula
    # checksum cannot be trusted: the sync must hash the real artefact.
    local file
    file="$(make_recipe "redis@8" "8.6.3" "staleaaaa" "file://${TEST_TMP}/redis-\${PACKAGE_VERSION}.tar.gz")"
    mv "$file" "${RECIPES_DIR}/redis@8.sh"
    printf 'hello\n' > "${TEST_TMP}/redis-8.10.1.tar.gz"

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]

    source "${LIB_DIR}/recipe.sh"
    # sha256 of "hello\n", a value independent of this codebase.
    [ "$(recipe_field "${RECIPES_DIR}/redis@8.sh" PACKAGE_SHA256)" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
}

@test "apply leaves a recipe untouched when its source cannot be hashed" {
    given_recipe "redis@8" "8.6.3" "staleaaaa" 'file:///nonexistent/redis-${PACKAGE_VERSION}.tar.gz'

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]
    [ "$(jq -r '.recipes[0].status' <<<"$output")" = "failed" ]

    source "${LIB_DIR}/recipe.sh"
    local file="${RECIPES_DIR}/redis@8.sh"
    # A half-written recipe would poison every build downstream.
    [ "$(recipe_field "$file" PACKAGE_VERSION)" = "8.6.3" ]
    [ "$(recipe_field "$file" PACKAGE_SHA256)" = "staleaaaa" ]
}

@test "one unresolvable recipe does not stop the others from syncing" {
    given_recipe "redis@8" "8.6.3"
    given_recipe "mysql@5" "5.7.0"

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]

    [ "$(jq -r '.recipes | length' <<<"$output")" -eq 2 ]
    [ "$(jq -r '.recipes[] | select(.recipe == "mysql@5") | .status' <<<"$output")" = "unresolved" ]
    [ "$(jq -r '.recipes[] | select(.recipe == "redis@8") | .status' <<<"$output")" = "updated" ]
}

@test "check flags a major line upstream opened that no recipe covers yet" {
    export BREW_API_BASE="file://${FIXTURES_DIR}/api-future"
    given_recipe "postgresql@18" "18.6" "x" 'https://ftp.postgresql.org/pub/source/v${PACKAGE_VERSION}/postgresql-${PACKAGE_VERSION}.tar.bz2'

    run --separate-stderr "$SYNC" check
    [ "$status" -eq 0 ]

    [ "$(jq -r '.new_major_lines | length' <<<"$output")" -eq 1 ]
    [ "$(jq -r '.new_major_lines[0]' <<<"$output")" = "postgresql@19" ]
}

@test "check does not flag a line another recipe already covers" {
    export BREW_API_BASE="file://${FIXTURES_DIR}/api-future"
    local url='https://ftp.postgresql.org/pub/source/v${PACKAGE_VERSION}/postgresql-${PACKAGE_VERSION}.tar.bz2'
    given_recipe "postgresql@17" "17.11" "x" "$url"
    given_recipe "postgresql@18" "18.6" "x" "$url"

    run --separate-stderr "$SYNC" check
    [ "$status" -eq 0 ]

    # 18 is tracked by a recipe of its own, so only the brand new line shows up.
    [ "$(jq -r '.new_major_lines | join(",")' <<<"$output")" = "postgresql@19" ]
}

@test "commit-message names what moved, so git history stays readable" {
    local report='{"command":"apply","recipes":[
        {"recipe":"redis@8","formula":"redis","from":"8.6.3","to":"8.10.1","status":"updated"},
        {"recipe":"zlib","formula":"zlib","from":"1.3.2","to":"1.3.2","status":"current"},
        {"recipe":"openssl@3","formula":"openssl@3","from":"3.6.2","to":"3.6.3","status":"updated"}],
        "new_major_lines":[]}'

    run --separate-stderr bash -c "printf '%s' '$report' | '$SYNC' commit-message"

    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "synchronise 2 recipes avec brew" ]
    [[ "$output" == *"redis@8 8.6.3 -> 8.10.1"* ]]
    [[ "$output" == *"openssl@3 3.6.2 -> 3.6.3"* ]]
    [[ "$output" != *"zlib"* ]]
}

@test "summary surfaces failures and new lines, not just the happy path" {
    local report='{"command":"apply","recipes":[
        {"recipe":"redis@8","formula":"redis","from":"8.6.3","to":"8.10.1","status":"updated"},
        {"recipe":"nss@3","formula":"nss","from":"3.124","to":"3.128","status":"failed"},
        {"recipe":"mysql@5","formula":null,"from":"5.7.0","to":null,"status":"unresolved"},
        {"recipe":"zlib","formula":"zlib","from":"1.3.2","to":"1.3.2","status":"current"}],
        "new_major_lines":["openssl@4"]}'

    run --separate-stderr bash -c "printf '%s' '$report' | '$SYNC' summary"

    [ "$status" -eq 0 ]
    [[ "$output" == *"redis@8"* ]]
    [[ "$output" == *"nss@3"* ]]
    [[ "$output" == *"mysql@5"* ]]
    [[ "$output" == *"openssl@4"* ]]
    # A run where nothing broke should not read the same as one where it did.
    [[ "$output" == *"failed"* ]]
    [[ "$output" == *"unresolved"* ]]
}

@test "summary of a check run lists what is behind, not an empty table" {
    local report='{"command":"check","recipes":[
        {"recipe":"redis@8","formula":"redis","from":"8.6.3","to":"8.10.1","status":"outdated"}],
        "new_major_lines":[]}'

    run --separate-stderr bash -c "printf '%s' '$report' | '$SYNC' summary"

    [ "$status" -eq 0 ]
    [[ "$output" == *"redis@8"* ]]
    [[ "$output" == *"8.10.1"* ]]
}

@test "commit records the synced recipes, and stays a no-op when nothing moved" {
    local repo="${TEST_TMP}/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email bot@test
    git -C "$repo" config user.name bot
    mkdir -p "${repo}/.github/scripts/recipes"
    cp "${REPO_ROOT}/.github/scripts/recipes/zlib.sh" "${repo}/.github/scripts/recipes/"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "initial"

    local report='{"command":"apply","recipes":[{"recipe":"zlib","formula":"zlib","from":"1.3.2","to":"1.4.0","status":"updated"}],"new_major_lines":[]}'

    # Nothing changed on disk yet: committing must not invent an empty commit.
    run --separate-stderr bash -c "cd '$repo' && printf '%s' '$report' | '$SYNC' commit"
    [ "$status" -eq 0 ]
    [ "$(git -C "$repo" rev-list --count HEAD)" -eq 1 ]

    source "${LIB_DIR}/recipe.sh"
    recipe_set_field "${repo}/.github/scripts/recipes/zlib.sh" PACKAGE_VERSION "1.4.0"

    run --separate-stderr bash -c "cd '$repo' && printf '%s' '$report' | '$SYNC' commit"
    [ "$status" -eq 0 ]
    [ "$(git -C "$repo" rev-list --count HEAD)" -eq 2 ]
    [[ "$(git -C "$repo" log -1 --pretty=%s)" == "synchronise 1 recipe avec brew" ]]
    [[ "$(git -C "$repo" log -1 --pretty=%b)" == *"zlib 1.3.2 -> 1.4.0"* ]]
}

@test "apply lets a recipe resolve the extra fields its URL needs" {
    # nss is the real case: the bundled tarball carries an NSPR version that
    # neither the formula nor the NSS version tells you.
    cat > "${RECIPES_DIR}/redis@8.sh" <<'RECIPE'
#!/bin/bash
export PACKAGE_NAME="redis@8"
export PACKAGE_VERSION="8.6.3"
export FLAVOR="old"
export PACKAGE_SHA256="staleaaaa"
export PACKAGE_URL="file://${SOURCE_ROOT}/redis-${PACKAGE_VERSION}-${FLAVOR}.tar.gz"

upstream_extra() {
    echo "FLAVOR=new"
}
RECIPE
    export SOURCE_ROOT="$TEST_TMP"
    printf 'hello\n' > "${TEST_TMP}/redis-8.10.1-new.tar.gz"

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]
    [ "$(jq -r '.recipes[0].status' <<<"$output")" = "updated" ]

    source "${LIB_DIR}/recipe.sh"
    [ "$(recipe_field "${RECIPES_DIR}/redis@8.sh" FLAVOR)" = "new" ]
    [ "$(recipe_field "${RECIPES_DIR}/redis@8.sh" PACKAGE_SHA256)" = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" ]
}

@test "apply gives up on a recipe whose extra fields cannot be resolved" {
    cat > "${RECIPES_DIR}/redis@8.sh" <<'RECIPE'
#!/bin/bash
export PACKAGE_NAME="redis@8"
export PACKAGE_VERSION="8.6.3"
export PACKAGE_SHA256="staleaaaa"
export PACKAGE_URL="https://download.redis.io/releases/redis-${PACKAGE_VERSION}.tar.gz"

upstream_extra() {
    echo "cannot reach the index" >&2
    return 1
}
RECIPE

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]
    [ "$(jq -r '.recipes[0].status' <<<"$output")" = "failed" ]

    source "${LIB_DIR}/recipe.sh"
    [ "$(recipe_field "${RECIPES_DIR}/redis@8.sh" PACKAGE_VERSION)" = "8.6.3" ]
}

@test "a recipe that does not replay upstream patches still gets its version, and says so" {
    # util-linux carries a patch Homebrew applies and this recipe does not.
    # Blocking the update would strand the recipe on an old version forever.
    given_recipe "util-linux" "2.42.1" "staleaaaa" \
        'https://mirrors.edge.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-${PACKAGE_VERSION}.tar.xz'

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]

    [ "$(jq -r '.recipes[0].status' <<<"$output")" = "updated" ]
    [ "$(jq -r '.recipes[0].patches_not_replayed' <<<"$output")" -eq 1 ]

    source "${LIB_DIR}/recipe.sh"
    [ "$(recipe_field "${RECIPES_DIR}/util-linux.sh" PACKAGE_VERSION)" = "2.42.2" ]
}

@test "summary names the recipes that diverge from the patches upstream applies" {
    local report='{"command":"apply","recipes":[
        {"recipe":"openssl@3","formula":"openssl@3","from":"3.6.2","to":"3.6.3","status":"updated","patches_not_replayed":4},
        {"recipe":"zlib","formula":"zlib","from":"1.3.2","to":"1.3.2","status":"current","patches_not_replayed":0}],
        "new_major_lines":[]}'

    run --separate-stderr bash -c "printf '%s' '$report' | '$SYNC' summary"

    [ "$status" -eq 0 ]
    [[ "$output" == *"openssl@3"*"4"* ]]
    [[ "$output" == *"patches"* ]]
}

@test "an unknown command fails instead of quietly doing something else" {
    given_recipe "redis@8" "8.6.3"

    run --separate-stderr "$SYNC" aply

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"usage"* ]]
}

@test "apply reports a formula whose build logic changed since it was reviewed" {
    export BREW_SOURCE_BASE="file://${FIXTURES_DIR}/formula-source"
    cat > "${RECIPES_DIR}/redis@8.sh" <<'RECIPE'
#!/bin/bash
export PACKAGE_NAME="redis@8"
export PACKAGE_VERSION="8.6.3"
export PACKAGE_SHA256="staleaaaa"
export PACKAGE_URL="https://download.redis.io/releases/redis-${PACKAGE_VERSION}.tar.gz"
export BREW_FORMULA_REVIEWED="0000000000000000000000000000000000000000000000000000000000000000"
RECIPE

    run --separate-stderr "$SYNC" apply
    [ "$status" -eq 0 ]

    [ "$(jq -r '.recipes[0].formula_changed' <<<"$output")" = "true" ]
    # The version still moves: a build-logic change must not strand a security fix.
    [ "$(jq -r '.recipes[0].status' <<<"$output")" = "updated" ]
    source "${LIB_DIR}/recipe.sh"
    [ "$(recipe_field "${RECIPES_DIR}/redis@8.sh" PACKAGE_VERSION)" = "8.10.1" ]
}

@test "summary points at the formula history when its build logic moved" {
    local report='{"command":"apply","recipes":[
        {"recipe":"redis@8","formula":"redis","from":"8.6.3","to":"8.10.1","status":"updated","patches_not_replayed":0,"formula_changed":true,"formula_path":"Formula/r/redis.rb"},
        {"recipe":"zlib","formula":"zlib","from":"1.3.2","to":"1.3.2","status":"current","patches_not_replayed":0,"formula_changed":false,"formula_path":"Formula/z/zlib.rb"}],
        "new_major_lines":[]}'

    run --separate-stderr bash -c "printf '%s' '$report' | '$SYNC' summary"

    [ "$status" -eq 0 ]
    [[ "$output" == *"redis@8"* ]]
    [[ "$output" == *"homebrew-core/commits/master/Formula/r/redis.rb"* ]]
    [[ "$output" != *"zlib.rb"* ]]
}

@test "review clears the signal, and the next sync stays quiet" {
    export BREW_SOURCE_BASE="${FIXTURES_DIR}/formula-source"
    export BREW_SOURCE_BASE="file://${FIXTURES_DIR}/formula-source"
    cat > "${RECIPES_DIR}/redis@8.sh" <<'RECIPE'
#!/bin/bash
export PACKAGE_NAME="redis@8"
export PACKAGE_VERSION="8.10.1"
export PACKAGE_SHA256="60166c95ab7aedaa9dfe516de685be0a4dd87be95ded59ba429df14c13f1b663"
export PACKAGE_URL="https://download.redis.io/releases/redis-${PACKAGE_VERSION}.tar.gz"
export BREW_FORMULA_REVIEWED="0000000000000000000000000000000000000000000000000000000000000000"
RECIPE

    run --separate-stderr "$SYNC" check
    [ "$(jq -r '.recipes[0].formula_changed' <<<"$output")" = "true" ]

    run --separate-stderr "$SYNC" review "redis@8"
    [ "$status" -eq 0 ]

    run --separate-stderr "$SYNC" check
    [ "$status" -eq 0 ]
    [ "$(jq -r '.recipes[0].formula_changed' <<<"$output")" = "false" ]
}
