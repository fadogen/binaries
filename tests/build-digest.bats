#!/usr/bin/env bats
#
# What a recipe contributes to a bundle is its source, its patches, its
# dependencies and the code that compiles them. Everything else is presentation.

bats_require_minimum_version 1.5.0

load helper

setup() {
    setup_tmpdir
    source "${LIB_DIR}/recipe.sh"
    RECIPE="${TEST_TMP}/pkg.sh"
    cat > "$RECIPE" <<'BASE'
export PACKAGE_NAME="pkg"
export PACKAGE_VERSION="1.0"
export PACKAGE_SHA256="aaaa"
export PACKAGE_URL="https://example.test/pkg-1.0.tar.gz"
export DEPENDENCIES=("openssl@3")
build() {
    ./configure --prefix="$1"
    make install
}
BASE
    BASELINE="$(recipe_build_digest "$RECIPE")"
}

teardown() {
    teardown_tmpdir
}

# Rewrites that change nothing about the binary produced.

@test "a comment does not change the digest" {
    printf '# explaining why\n' >> "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" = "$BASELINE" ]
}

@test "reindenting the build function does not change the digest" {
    perl -0pi -e 's/^    \./        ./gm' "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" = "$BASELINE" ]
}

@test "changing the source URL does not change the digest" {
    perl -0pi -e 's{https://example.test/}{https://mirror.test/}' "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" = "$BASELINE" ]
}

@test "adding a mirror does not change the digest" {
    printf 'export PACKAGE_MIRRORS=("https://mirror.test/pkg-1.0.tar.gz")\n' >> "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" = "$BASELINE" ]
}

@test "recording a formula review or a licence does not change the digest" {
    printf 'export BREW_FORMULA_REVIEWED="deadbeef"\nexport PACKAGE_LICENSE="MIT"\n' >> "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" = "$BASELINE" ]
}

# Changes that alter what ships.

@test "a different source changes the digest" {
    perl -0pi -e 's/PACKAGE_SHA256="aaaa"/PACKAGE_SHA256="bbbb"/' "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" != "$BASELINE" ]
}

@test "a different build changes the digest" {
    perl -0pi -e 's/--prefix="\$1"/--prefix="\$1" --with-extra/' "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" != "$BASELINE" ]
}

@test "a new dependency changes the digest" {
    perl -0pi -e 's/DEPENDENCIES=\("openssl\@3"\)/DEPENDENCIES=("openssl\@3" "zlib")/' "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" != "$BASELINE" ]
}

@test "a new build dependency changes the digest" {
    printf 'export BUILD_DEPENDENCIES=("cmake")\n' >> "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" != "$BASELINE" ]
}

@test "a patch checksum change changes the digest" {
    printf 'declare -a PATCH_CHECKSUMS=("1111")\n' >> "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" != "$BASELINE" ]
}

@test "a variable the build function reads changes the digest" {
    printf 'export EXTRA_CFLAGS="-O3"\n' >> "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" != "$BASELINE" ]
}

@test "adding post_install changes the digest" {
    printf 'post_install() { chmod 0755 "$1"/lib/*.so; }\n' >> "$RECIPE"
    [ "$(recipe_build_digest "$RECIPE")" != "$BASELINE" ]
}

@test "a trailing semicolon in a reprinted function does not change the digest" {
    # bash 5.2 and 5.3 disagree on whether the last command of a block gets a
    # trailing semicolon when `declare -f` reprints it. Without normalising, the
    # digest would depend on the bash that computed it, and a runner image
    # upgrade would rebuild every bundle.
    local WITH_SEMI="${TEST_TMP}/semi.sh"
    sed 's/    make install/    make install;/' "$RECIPE" > "$WITH_SEMI"

    [ "$(recipe_build_digest "$WITH_SEMI")" = "$BASELINE" ]
}
