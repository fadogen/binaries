#!/bin/bash
# Build recipe for pcre2
# Description: Perl compatible regular expressions library with a new API

set -e

# Metadata
export PACKAGE_NAME="pcre2"
export PACKAGE_VERSION="10.47"
export PACKAGE_SHA256="47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7"

# Derived from version
export PACKAGE_URL="https://github.com/PCRE2Project/${PACKAGE_NAME}/releases/download/${PACKAGE_NAME}-${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.bz2"

# No runtime dependencies
export DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    cd "${SOURCE_DIR}"

    # Configure
    ./configure \
        --disable-dependency-tracking \
        --prefix="${PREFIX}" \
        --enable-pcre2-16 \
        --enable-pcre2-32 \
        --enable-pcre2grep-libz \
        --enable-pcre2grep-libbz2 \
        --enable-jit \
        --enable-pcre2test-libedit

    # Build
    make -j"$(sysctl -n hw.ncpu)"

    # Install
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
