#!/bin/bash
# Build recipe for simdjson
# Description: SIMD-accelerated C++ JSON parser

set -e

# Metadata
export PACKAGE_NAME="simdjson"
export PACKAGE_VERSION="4.2.4"
export PACKAGE_SHA256="6f942d018561a6c30838651a386a17e6e4abbfc396afd0f62740dea1810dedea"

# Derived from version
export PACKAGE_URL="https://github.com/simdjson/simdjson/archive/refs/tags/v${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# Build dependencies (via Homebrew)
export BUILD_DEPENDENCIES=(
    "cmake"
)

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect OS
    local OS_NAME
    OS_NAME="$(uname)"

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

    # Configure with CMake
    cmake -S . -B build \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DSIMDJSON_BUILD_STATIC_LIB=ON

    # Build
    cmake --build build -j"$NPROC"

    # Install
    cmake --install build

    echo "✓ ${PACKAGE_NAME} built successfully"
}
