#!/bin/bash
# Build recipe for ca-certificates (Mozilla CA certificate bundle)
# Source: https://curl.se/docs/caextract.html

set -e

# Metadata
export PACKAGE_NAME="ca-certificates"
export PACKAGE_VERSION="2026-05-14"
export PACKAGE_SHA256="86a1f3366afac7c6f8ae9f3c779ac221129328c43f0ab2b8817eb2f362a5025c"

# Derived from version
export PACKAGE_URL="https://curl.se/ca/cacert-${PACKAGE_VERSION}.pem"

# No dependencies
export DEPENDENCIES=()

# Build function (not needed, just install)
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Installing ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    mkdir -p "${PREFIX}/share/ca-certificates"
    cp "${SOURCE_DIR}/cacert-${PACKAGE_VERSION}.pem" "${PREFIX}/share/ca-certificates/cacert.pem"

    echo "✓ ${PACKAGE_NAME} installed successfully"
}
