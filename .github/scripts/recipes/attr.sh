#!/bin/bash
# Build recipe for attr
# Description: Manipulate filesystem extended attributes

set -e

# Metadata
export PACKAGE_NAME="attr"
export PACKAGE_VERSION="2.5.2"
export PACKAGE_SHA256="39bf67452fa41d0948c2197601053f48b3d78a029389734332a6309a680c6c87"

# Derived from version
export PACKAGE_URL="https://download.savannah.nongnu.org/releases/${PACKAGE_NAME}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

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
