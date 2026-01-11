#!/bin/bash
# Build recipe for xz
# Description: General-purpose data compression with high compression ratio

set -e

# Metadata
export PACKAGE_NAME="xz"
export PACKAGE_VERSION="5.8.2"
export PACKAGE_SHA256="ce09c50a5962786b83e5da389c90dd2c15ecd0980a258dd01f70f9e7ce58a8f1"

# Derived from version
export PACKAGE_URL="https://github.com/tukaani-project/${PACKAGE_NAME}/releases/download/v${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Dependencies are installed in $PREFIX (parent_prefix logic)
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"
    # Add headerpad for install_name_tool (CRITICAL for relocation)
    export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"

    cd "${SOURCE_DIR}"

    # Configure
    ./configure \
        --prefix="${PREFIX}" \
        --disable-silent-rules \
        --disable-nls

    # Build
    make -j"$(sysctl -n hw.ncpu)"

    # Run tests (as per Homebrew formula)
    echo "→ Running tests..."
    make check

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
