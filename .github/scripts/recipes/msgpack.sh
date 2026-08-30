#!/bin/bash
# Build recipe for msgpack
# Description: Library for a binary-based efficient data interchange format

set -e

# Metadata
export PACKAGE_NAME="msgpack"
export PACKAGE_VERSION="7.0.2"
export PACKAGE_SHA256="6ae50f69612871aa01de76bec904165cd2a2fc30ff9f653f2f60a663c5c1a86c"
export PACKAGE_LICENSE="BSL-1.0"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="8270e2dbf92bdc5c8602abc429a63534f6778248e81587252a5d43a479baabbe"

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
