#!/bin/bash
# Build recipe for lz4
# Description: Extremely Fast Compression algorithm

set -e

# Metadata
export PACKAGE_NAME="lz4"
export PACKAGE_VERSION="1.10.0"
export PACKAGE_SHA256="537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"

# Derived from version
export PACKAGE_URL="https://github.com/${PACKAGE_NAME}/${PACKAGE_NAME}/archive/refs/tags/v${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Set environment
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"
    # Add headerpad for install_name_tool (CRITICAL for relocation)
    export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"

    cd "${SOURCE_DIR}"

    # Build with make (lz4 doesn't use configure)
    make -j"$(sysctl -n hw.ncpu)" PREFIX="${PREFIX}"

    # Install directly to final location
    make install PREFIX="${PREFIX}"

    # Fix pkgconfig file to use correct prefix
    local PC_FILE="${PREFIX}/lib/pkgconfig/liblz4.pc"
    if [ -f "$PC_FILE" ]; then
        sed -i '' "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE"
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}
