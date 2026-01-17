#!/bin/bash
# Build recipe for libtirpc
# Description: Port of Sun's Transport-Independent RPC library to Linux

set -e

# Metadata
export PACKAGE_NAME="libtirpc"
export PACKAGE_VERSION="1.3.7"
export PACKAGE_SHA256="b47d3ac19d3549e54a05d0019a6c400674da716123858cfdb6d3bdd70a66c702"

# Derived from version
export PACKAGE_URL="https://downloads.sourceforge.net/project/${PACKAGE_NAME}/${PACKAGE_NAME}/${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.bz2"

# Runtime dependencies
export DEPENDENCIES=(
    "krb5"
)

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

    # Platform-specific flags
    case "$OS_NAME" in
        Darwin)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            # macOS-specific flag for RFC 3542 compliance
            export CFLAGS="-D__APPLE_USE_RFC_3542"
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

    # Configure (keep debug enabled as per Homebrew formula)
    ./configure \
        --prefix="${PREFIX}" \
        --disable-silent-rules

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
