#!/bin/bash
# Build recipe for krb5
# Description: Network authentication protocol

set -e

# Metadata
export PACKAGE_NAME="krb5"
export PACKAGE_VERSION="1.22.2"
export PACKAGE_SHA256="3243ffbc8ea4d4ac22ddc7dd2a1dc54c57874c40648b60ff97009763554eaf13"
export PACKAGE_LICENSE="BSD-2-Clause AND BSD-2-Clause-first-lines AND BSD-3-Clause AND BSD-4-Clause AND Brian-Gladman-2-Clause AND CMU-Mach-nodoc AND FSFULLRWD AND HPND AND HPND-export2-US AND HPND-export-US AND HPND-export-US-acknowledgement AND HPND-export-US-modify AND ISC AND MIT AND MIT-CMU AND OLDAP-2.8 AND OpenVision AND (BSD-2-Clause OR GPL-2.0-or-later)"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="1d85e0d26dc99d965d1d3e4408777e8395c664ccd860a8104b52b88eb2157d98"

# Derived from version (URL uses major.minor in path)
PACKAGE_VERSION_SHORT="${PACKAGE_VERSION%.*}"
export PACKAGE_URL="https://kerberos.org/dist/${PACKAGE_NAME}/${PACKAGE_VERSION_SHORT}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# kerberos.org goes down for minutes at a time and broke two consecutive runs.
# MIT is where krb5 comes from, and serves the same archive.
export PACKAGE_MIRRORS=(
    "https://web.mit.edu/kerberos/dist/${PACKAGE_NAME}/${PACKAGE_VERSION_SHORT}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"
)

# Runtime dependencies (must be built first)
export DEPENDENCIES=(
    "openssl@3"
)

# Linux-specific dependencies
export DEPENDENCIES_LINUX=(
    "keyutils"
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

    # Platform-specific LDFLAGS
    case "$OS_NAME" in
        Darwin)
            # Add headerpad for install_name_tool (CRITICAL for relocation on macOS)
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

    # Change to src directory (krb5 builds from src/)
    cd "${SOURCE_DIR}/src"

    # Configure (matches Homebrew's std_configure_args + formula options)
    ./configure \
        --prefix="${PREFIX}" \
        --disable-debug \
        --disable-dependency-tracking \
        --disable-nls \
        --disable-silent-rules \
        --without-system-verto

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
