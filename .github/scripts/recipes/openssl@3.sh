#!/bin/bash
# Build recipe for openssl
# Description: Cryptography and SSL/TLS toolkit

set -e

# Metadata
export PACKAGE_NAME="openssl@3"
export PACKAGE_VERSION="3.6.0"
export PACKAGE_SHA256="b6a5f44b7eb69e3fa35dbf15524405b44837a481d43d81daddde3ff21fcbb8e9"

# Derived from version
export PACKAGE_URL="https://github.com/openssl/openssl/releases/download/openssl-${PACKAGE_VERSION}/openssl-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "ca-certificates"
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

    # Detect architecture
    local OPENSSL_TARGET
    if [[ "$(uname -m)" == "arm64" ]]; then
        OPENSSL_TARGET="darwin64-arm64-cc"
    else
        OPENSSL_TARGET="darwin64-x86_64-cc"
    fi

    # Configure for macOS
    ./Configure \
        "$OPENSSL_TARGET" \
        --prefix="${PREFIX}" \
        --openssldir="${PREFIX}/etc/openssl@3" \
        --libdir=lib \
        enable-ec_nistp_64_gcc_128 \
        no-ssl3 \
        no-ssl3-method \
        no-zlib

    # Build
    make -j"$(sysctl -n hw.ncpu)"

    # Install directly to final location
    make install_sw install_ssldirs

    echo "✓ ${PACKAGE_NAME} built successfully"
}

# Post-install: Link ca-certificates to OpenSSL
post_install() {
    local PREFIX="$1"

    echo "Linking ca-certificates to OpenSSL..."

    local ca_cert="${PREFIX}/share/ca-certificates/cacert.pem"

    if [ -f "$ca_cert" ]; then
        echo "  Found ca-certificates at: $ca_cert"
        ln -sf "../../share/ca-certificates/cacert.pem" "${PREFIX}/etc/openssl@3/cert.pem"
        echo "  → Created relative symlink at ${PREFIX}/etc/openssl@3/cert.pem"
    else
        echo "  ⚠ Warning: ca-certificates not found at $ca_cert"
    fi
}
