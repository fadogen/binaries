#!/bin/bash
# Build recipe for lzo
# Description: Real-time data compression library

set -e

# Metadata
export PACKAGE_NAME="lzo"
export PACKAGE_VERSION="2.10"
export PACKAGE_SHA256="c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072"
export PACKAGE_LICENSE="GPL-2.0-or-later"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="10a3baef9de860a1974d82f8ab807f0ab71b059e5725fa720be283d34156e1c6"

# Derived from version
export PACKAGE_URL="https://www.oberhumer.com/opensource/${PACKAGE_NAME}/download/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# No build dependencies
export BUILD_DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect number of CPU cores (cross-platform)
    local NPROC
    if command -v nproc >/dev/null 2>&1; then
        NPROC=$(nproc)
    elif command -v sysctl >/dev/null 2>&1; then
        NPROC=$(sysctl -n hw.ncpu)
    else
        NPROC=4
    fi

    cd "${SOURCE_DIR}"

    # Configure
    ./configure \
        --disable-dependency-tracking \
        --prefix="${PREFIX}" \
        --enable-shared

    # Build
    make -j"$NPROC"

    # Test
    make check

    # Install
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
