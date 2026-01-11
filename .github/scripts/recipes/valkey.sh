#!/bin/bash
# Build recipe for valkey
# Description: High-performance data structure server that primarily serves key/value workloads

set -e

# Metadata
export PACKAGE_NAME="valkey"
export PACKAGE_VERSION="9.0.1"
export PACKAGE_SHA256="9cfbc5f32a2a6058ee0f8c532b9c4d24167cc49d719f091dd75f1bb8353a1fc5"

# Derived from version
export PACKAGE_URL="https://github.com/valkey-io/${PACKAGE_NAME}/archive/refs/tags/${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "openssl@3"
)

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

    # Build with make (valkey doesn't use configure)
    # BUILD_TLS=yes enables TLS support with OpenSSL
    make -j"$(sysctl -n hw.ncpu)" \
        PREFIX="${PREFIX}" \
        CC="${CC:-cc}" \
        BUILD_TLS=yes

    # Install directly to final location
    make install PREFIX="${PREFIX}"

    echo "✓ ${PACKAGE_NAME} built successfully"
}
