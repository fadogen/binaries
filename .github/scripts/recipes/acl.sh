#!/bin/bash
# Build recipe for acl
# Description: Commands for manipulating POSIX access control lists

set -e

# Metadata
export PACKAGE_NAME="acl"
export PACKAGE_VERSION="2.4.0"
export PACKAGE_SHA256="73c853c3d44e1f693e5a96a986f1bd19d3d0dac2c7d453e796177774bc4e5f6a"
export PACKAGE_LICENSE="GPL-2.0-or-later AND LGPL-2.1-or-later"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="740cc53275ca9b48b0ce3d21254b00bec0933757625eab61083673f3808a8c59"

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
