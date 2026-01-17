#!/bin/bash
# Build recipe for libedit
# Description: BSD-style licensed readline alternative

set -e

# Metadata
export PACKAGE_NAME="libedit"
export PACKAGE_VERSION="20251016-3.1"
export PACKAGE_SHA256="21362b00653bbfc1c71f71a7578da66b5b5203559d43134d2dd7719e313ce041"

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
