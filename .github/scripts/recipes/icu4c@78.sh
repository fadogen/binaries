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

    # Detect OS
    local OS_NAME
    OS_NAME="$(uname)"

    # ICU builds from the "source" subdirectory
    cd "${SOURCE_DIR}/source"

    # Platform-specific LDFLAGS
    case "$OS_NAME" in
        Darwin)
            # Add headerpad for install_name_tool (CRITICAL for relocation on macOS)
            export LDFLAGS="-Wl,-headerpad_max_install_names"
            ;;
        *)
            export LDFLAGS=""
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

    # Configure arguments (from Homebrew formula)
    local args=(
        "--prefix=${PREFIX}"
        "--disable-debug"
        "--disable-dependency-tracking"
        "--disable-samples"
        "--disable-tests"
        "--enable-static"
        "--with-library-bits=64"
    )

    # Configure
    ./configure "${args[@]}"

    # Build (parallel)
    make -j"$NPROC"

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
