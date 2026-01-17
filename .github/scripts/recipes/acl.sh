#!/bin/bash
# Build recipe for acl
# Description: Commands for manipulating POSIX access control lists

set -e

# Metadata
export PACKAGE_NAME="acl"
export PACKAGE_VERSION="2.3.2"
export PACKAGE_SHA256="5f2bdbad629707aa7d85c623f994aa8a1d2dec55a73de5205bac0bf6058a2f7c"

# Derived from version
export PACKAGE_URL="https://download.savannah.nongnu.org/releases/${PACKAGE_NAME}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "attr"
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
