#!/bin/bash
# Build recipe for icu4c
# Description: International Components for Unicode (C/C++ libraries)

set -e

# Metadata
export PACKAGE_NAME="icu4c@78"
export PACKAGE_VERSION="78.2"
export PACKAGE_SHA256="3e99687b5c435d4b209630e2d2ebb79906c984685e78635078b672e03c89df35"

# Derived from version
export PACKAGE_URL="https://github.com/unicode-org/icu/releases/download/release-${PACKAGE_VERSION}/icu4c-${PACKAGE_VERSION}-sources.tgz"

# No runtime dependencies (keg_only, self-contained)
export DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # ICU builds from the "source" subdirectory
    cd "${SOURCE_DIR}/source"

    # Add headerpad for install_name_tool (CRITICAL for relocation)
    export LDFLAGS="-Wl,-headerpad_max_install_names"

    # Configure arguments (from Homebrew formula)
    local args=(
        "--prefix=${PREFIX}"
        "--disable-samples"      # Don't build sample programs
        "--disable-tests"        # Don't build tests
        "--enable-static"        # Build static libraries
        "--with-library-bits=64" # 64-bit build
    )

    # Configure
    ./configure "${args[@]}"

    # Build (parallel)
    make -j"$(sysctl -n hw.ncpu)"

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
