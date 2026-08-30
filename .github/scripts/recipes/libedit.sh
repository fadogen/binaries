#!/bin/bash
# Build recipe for libedit
# Description: BSD-style licensed readline alternative

set -e

# Metadata
export PACKAGE_NAME="libedit"
export PACKAGE_VERSION="20260512-3.1"
export PACKAGE_SHA256="432d5e7ea8b0116dd39f2eca7bc11d0eed77faa6b77ea526ace89907c23ea4a0"
export PACKAGE_LICENSE="BSD-3-Clause"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="2c7ea8e8a2f585aead6c43d3dd7389dbfe4d520b29952dec82b7becdaa8fda66"

# Derived from version
export PACKAGE_URL="https://thrysoee.dk/editline/libedit-${PACKAGE_VERSION}.tar.gz"

# Linux only (macOS provides libedit via system)
export LINUX_ONLY=true

# No recipe dependencies - uses system ncurses (present on all Linux distros)

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect number of CPU cores
    local NPROC
    if command -v nproc >/dev/null 2>&1; then
        NPROC=$(nproc)
    else
        NPROC=4
    fi

    cd "${SOURCE_DIR}"

    # Use system ncurses (available on all Linux distros)
    # This avoids bundling ncurses which is a large library
    export LDFLAGS="-L/usr/lib"
    export CPPFLAGS="-I/usr/include"

    # Configure
    ./configure \
        --prefix="${PREFIX}" \
        --disable-silent-rules

    # Build
    make -j"$NPROC"

    # Install
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
