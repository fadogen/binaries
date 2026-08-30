#!/bin/bash
# Build recipe for libnsl
# Description: Public client interface for NIS(YP) and NIS+

set -e

# Metadata
export PACKAGE_NAME="libnsl"
export PACKAGE_VERSION="2.0.1"
export PACKAGE_SHA256="5c9e470b232a7acd3433491ac5221b4832f0c71318618dc6aa04dd05ffcd8fd9"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="b2616489bc18557917d483fddefcd26590974ecde33de86c877ad80faab0f94f"

# Derived from version
export PACKAGE_URL="https://github.com/thkukuk/${PACKAGE_NAME}/releases/download/v${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.xz"

# Runtime dependencies
export DEPENDENCIES=(
    "libtirpc"
)

# Linux only
export LINUX_ONLY=true

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Check if running on Linux
    if [ "$(uname)" != "Linux" ]; then
        echo "⚠ ${PACKAGE_NAME} is Linux only, skipping on $(uname)"
        return 0
    fi

    # Set environment
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"
    export LDFLAGS="-L${PREFIX}/lib"

    # Detect number of CPU cores
    local NPROC
    if command -v nproc >/dev/null 2>&1; then
        NPROC=$(nproc)
    else
        NPROC=4
    fi

    cd "${SOURCE_DIR}"

    # Configure
    ./configure \
        --prefix="${PREFIX}" \
        --disable-silent-rules

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
