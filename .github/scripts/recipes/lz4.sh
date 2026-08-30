#!/bin/bash
# Build recipe for lz4
# Description: Extremely Fast Compression algorithm

set -e

# Metadata
export PACKAGE_NAME="lz4"
export PACKAGE_VERSION="1.10.0"
export PACKAGE_SHA256="537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"
export PACKAGE_LICENSE="BSD-2-Clause"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="9d70c2a481a94f961772b89d4f8413a2fd01d471d5101855a37f1dfd360aa631"

# Derived from version
export PACKAGE_URL="https://github.com/${PACKAGE_NAME}/${PACKAGE_NAME}/archive/refs/tags/v${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect OS
    local OS_NAME
    OS_NAME="$(uname)"

    # Set environment
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"

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

    # Build with make (lz4 doesn't use configure)
    make -j"$NPROC" PREFIX="${PREFIX}"

    # Install directly to final location
    make install PREFIX="${PREFIX}"

    # Fix pkgconfig file to use correct prefix
    local PC_FILE="${PREFIX}/lib/pkgconfig/liblz4.pc"
    if [ -f "$PC_FILE" ]; then
        case "$OS_NAME" in
            Darwin) sed -i '' "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE" ;;
            *) sed -i "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE" ;;
        esac
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}
