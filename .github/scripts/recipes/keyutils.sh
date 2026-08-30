#!/bin/bash
# Build recipe for keyutils
# Description: Linux key management utilities
# Note: This package is Linux-only (used as dependency for krb5 on Linux)

set -e

# Metadata
export PACKAGE_NAME="keyutils"
export PACKAGE_VERSION="1.6.3"
export PACKAGE_SHA256="a61d5706136ae4c05bd48f86186bcfdbd88dd8bd5107e3e195c924cfc1b39bb4"
export PACKAGE_LICENSE="GPL-2.0-or-later AND LGPL-2.0-or-later"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="1995a1d47d28ec97ca4b72c9f703651d6ae0e2afd4c36f8d742ce9fe0a83f49c"

# Derived from version
export PACKAGE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/dhowells/keyutils.git/snapshot/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect OS - keyutils is Linux-only
    local OS_NAME
    OS_NAME="$(uname)"

    if [[ "$OS_NAME" == "Darwin" ]]; then
        echo "Warning: keyutils is Linux-only, skipping build on macOS"
        return 0
    fi

    # Detect number of CPU cores
    local NPROC
    if command -v nproc >/dev/null 2>&1; then
        NPROC=$(nproc)
    else
        NPROC=4
    fi

    cd "${SOURCE_DIR}"

    # Fix paths in request-key.conf (as Homebrew does)
    sed -i "s|\\s/bin/key|${PREFIX}/bin/key|g" request-key.conf
    sed -i "s|\\s/sbin/key|${PREFIX}/sbin/key|g" request-key.conf
    sed -i "s|\\s/usr/share/${PACKAGE_NAME}/|${PREFIX}/share/${PACKAGE_NAME}/|g" request-key.conf

    # Build and install with correct paths
    # keyutils uses make directly without configure
    make -j"$NPROC" \
        BINDIR="${PREFIX}/bin" \
        ETCDIR="${PREFIX}/etc" \
        INCLUDEDIR="${PREFIX}/include" \
        LIBDIR="${PREFIX}/lib" \
        MANDIR="${PREFIX}/share/man" \
        SBINDIR="${PREFIX}/sbin" \
        SHAREDIR="${PREFIX}/share/${PACKAGE_NAME}" \
        USRLIBDIR="${PREFIX}/lib"

    make install \
        BINDIR="${PREFIX}/bin" \
        ETCDIR="${PREFIX}/etc" \
        INCLUDEDIR="${PREFIX}/include" \
        LIBDIR="${PREFIX}/lib" \
        MANDIR="${PREFIX}/share/man" \
        SBINDIR="${PREFIX}/sbin" \
        SHAREDIR="${PREFIX}/share/${PACKAGE_NAME}" \
        USRLIBDIR="${PREFIX}/lib"

    echo "✓ ${PACKAGE_NAME} built successfully"
}
