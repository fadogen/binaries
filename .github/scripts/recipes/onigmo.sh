#!/bin/bash
# Build recipe for onigmo
# Description: Regular expressions library forked from Oniguruma

set -e

# Metadata
export PACKAGE_NAME="onigmo"
export PACKAGE_VERSION="6.2.0"
export PACKAGE_SHA256="c648496b5339953b925ebf44b8de356feda8d3428fa07dc1db95bfe2570feb76"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="26e4a1b04f1252d3f92d9e238dbe43bde6ee5f9f465c38a1a7714718c5314a09"

# Derived from version
export PACKAGE_URL="https://github.com/k-takata/Onigmo/releases/download/Onigmo-${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# No build dependencies
export BUILD_DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect OS
    local OS_NAME
    OS_NAME="$(uname)"

    # Platform-specific LDFLAGS
    case "$OS_NAME" in
        Darwin)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            ;;
        *)
            export LDFLAGS="-L${PREFIX}/lib"
            ;;
    esac

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
        --prefix="${PREFIX}" \
        --disable-dependency-tracking

    # Build
    make -j"$NPROC"

    # Install
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
