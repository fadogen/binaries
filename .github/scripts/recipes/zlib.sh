#!/bin/bash
# Build recipe for zlib
# Description: General-purpose lossless data-compression library

set -e

# Metadata
export PACKAGE_NAME="zlib"
export PACKAGE_VERSION="1.3.1"
export PACKAGE_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"

# Derived from version
export PACKAGE_URL="https://zlib.net/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

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

    # Dependencies are installed in $PREFIX (parent_prefix logic)
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

    # Configure
    ./configure --prefix="${PREFIX}"

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    # Fix pkgconfig file to use correct prefix
    local PC_FILE="${PREFIX}/lib/pkgconfig/zlib.pc"
    if [ -f "$PC_FILE" ]; then
        case "$OS_NAME" in
            Darwin) sed -i '' "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE" ;;
            *) sed -i "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE" ;;
        esac
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}
