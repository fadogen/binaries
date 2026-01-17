#!/bin/bash
# Build recipe for msgpack
# Description: Library for a binary-based efficient data interchange format

set -e

# Metadata
export PACKAGE_NAME="msgpack"
export PACKAGE_VERSION="6.1.0"
export PACKAGE_SHA256="674119f1a85b5f2ecc4c7d5c2859edf50c0b05e0c10aa0df85eefa2c8c14b796"

# Derived from version (msgpack-c uses c-VERSION tag format)
export PACKAGE_URL="https://github.com/msgpack/msgpack-c/releases/download/c-${PACKAGE_VERSION}/msgpack-c-${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# Build dependencies (via Homebrew, not in bundle)
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
        -DMSGPACK_BUILD_TESTS=OFF

    # Build
    cmake --build build -j"$NPROC"

    # Install
    cmake --install build

    # Create compatibility symlinks (libmsgpack-c -> libmsgpackc)
    # This maintains compatibility with older software expecting libmsgpackc
    cd "${PREFIX}/lib"

    case "$OS_NAME" in
        Darwin)
            for dylib in libmsgpack-c*.dylib; do
                if [ -f "$dylib" ]; then
                    local old_name="${dylib//msgpack-c/msgpackc}"
                    ln -sf "$dylib" "$old_name"
                fi
            done
            ;;
        *)
            for solib in libmsgpack-c.so*; do
                if [ -f "$solib" ]; then
                    local old_name="${solib//msgpack-c/msgpackc}"
                    ln -sf "$solib" "$old_name"
                fi
            done
            ;;
    esac

    echo "✓ ${PACKAGE_NAME} built successfully"
}
