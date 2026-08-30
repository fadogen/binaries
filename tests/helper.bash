#!/usr/bin/env bash
# Shared helpers for the bats suite.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export SCRIPTS_DIR="${REPO_ROOT}/.github/scripts"
export LIB_DIR="${SCRIPTS_DIR}/lib"
export RECIPES_DIR="${SCRIPTS_DIR}/recipes"
export FIXTURES_DIR="${REPO_ROOT}/tests/fixtures"

# Isolated scratch directory, wiped between tests.
setup_tmpdir() {
    TEST_TMP="$(mktemp -d)"
    export TEST_TMP
}

teardown_tmpdir() {
    [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
    return 0
}

# Write a minimal recipe file and echo its path.
make_recipe() {
    local name="$1" version="$2" sha256="${3:-deadbeef}"
    # Single quotes on purpose: the template must reach the recipe unexpanded.
    local url="$4"
    [[ -n "$url" ]] || url='https://example.test/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz'
    local file="${TEST_TMP}/${name}.sh"
    cat > "$file" <<RECIPE
#!/bin/bash
# Build recipe for ${name}

set -e

# Metadata
export PACKAGE_NAME="${name}"
export PACKAGE_VERSION="${version}"
export PACKAGE_SHA256="${sha256}"

# Derived from version
export PACKAGE_URL="${url}"

build() {
    echo "building \${PACKAGE_NAME} \${PACKAGE_VERSION}"
}
RECIPE
    echo "$file"
}
