#!/bin/bash
# Build recipe for ca-certificates (Mozilla CA certificate bundle)
# Source: https://curl.se/docs/caextract.html

set -e

# Metadata
export PACKAGE_NAME="ca-certificates"
export PACKAGE_VERSION="2025-12-02"
export PACKAGE_SHA256="f1407d974c5ed87d544bd931a278232e13925177e239fca370619aba63c757b4"

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
