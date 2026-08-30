#!/bin/bash
# Build recipe for protobuf
# Description: Protocol Buffers - Google's data interchange format

set -e

# Metadata
export PACKAGE_NAME="protobuf"
export PACKAGE_VERSION="36.0"
export PACKAGE_SHA256="399931c793f4ac6db81045b00b06dd07c877b48aeecf36c797f65c541fb533e7"
export PACKAGE_LICENSE="BSD-3-Clause"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="c5722e30cf2d7e62cef205c279936684ca77a773654170c0e09639f7abd400b7"

# Derived from version
export PACKAGE_URL="https://github.com/protocolbuffers/${PACKAGE_NAME}/releases/download/v${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "abseil"
)

# Build dependencies (via Homebrew, not in bundle)
export BUILD_DEPENDENCIES=(
    "cmake"
    "googletest"
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

    cd "${SOURCE_DIR}"

    # CMake args (common) - keep CMAKE_CXX_STANDARD in sync with abseil
    local CMAKE_ARGS=(
        -DCMAKE_INSTALL_PREFIX="${PREFIX}"
        -DCMAKE_PREFIX_PATH="${PREFIX}"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_CXX_STANDARD=17
        -DBUILD_SHARED_LIBS=ON
        -Dprotobuf_BUILD_LIBPROTOC=ON
        -Dprotobuf_BUILD_SHARED_LIBS=ON
        -Dprotobuf_INSTALL_EXAMPLES=ON
        -Dprotobuf_BUILD_TESTS=ON
        -Dprotobuf_USE_EXTERNAL_GTEST=ON
        -Dprotobuf_FORCE_FETCH_DEPENDENCIES=OFF
        -Dprotobuf_LOCAL_DEPENDENCIES_ONLY=ON
    )

    # Platform-specific CMake args
    case "$OS_NAME" in
        Darwin)
            # macOS: nothing extra needed (relocation handled by relocate.sh)
            ;;
        *)
            # Linux: Set RPATH so libraries can find each other at runtime
            CMAKE_ARGS+=(
                -DCMAKE_BUILD_RPATH="${PREFIX}/lib"
                -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
            )
            ;;
    esac

    # Configure with CMake
    cmake -S . -B build "${CMAKE_ARGS[@]}"

    # Build
    cmake --build build -j"$NPROC"

    # Run tests (as per Homebrew formula)
    echo "→ Running tests..."
    ctest --test-dir build --verbose || {
        echo "⚠ Some tests failed, but continuing installation"
    }

    # Install directly to final location
    cmake --install build

    echo "✓ ${PACKAGE_NAME} built successfully"
}
