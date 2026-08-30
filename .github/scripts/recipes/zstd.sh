#!/bin/bash
# Build recipe for zstd
# Description: Zstandard is a real-time compression algorithm

set -e

# Metadata
export PACKAGE_NAME="zstd"
export PACKAGE_VERSION="1.5.7"
export PACKAGE_SHA256="37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="7ee9615d4d8cf2bdd70aed50269cb65915e4a1cd46a3fada64b5a40f22c0ef17"

# Derived from version
export PACKAGE_URL="https://github.com/facebook/${PACKAGE_NAME}/archive/refs/tags/v${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "lz4"
    "xz"
    "zlib"
)

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

    # Dependencies are installed in $PREFIX (parent_prefix logic)
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"

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
    cmake -S build/cmake -B builddir \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DZSTD_PROGRAMS_LINK_SHARED=ON \
        -DZSTD_BUILD_CONTRIB=ON \
        -DZSTD_LEGACY_SUPPORT=ON \
        -DZSTD_ZLIB_SUPPORT=ON \
        -DZSTD_LZMA_SUPPORT=ON \
        -DZSTD_LZ4_SUPPORT=ON \
        -DCMAKE_CXX_STANDARD=11

    # Build
    cmake --build builddir -j"$NPROC"

    # Install directly to final location
    cmake --install builddir

    # Fix pkgconfig file to use correct prefix
    local PC_FILE="${PREFIX}/lib/pkgconfig/libzstd.pc"
    if [ -f "$PC_FILE" ]; then
        case "$OS_NAME" in
            Darwin) sed -i '' "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE" ;;
            *) sed -i "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE" ;;
        esac
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}
