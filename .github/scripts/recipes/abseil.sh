#!/bin/bash
# Build recipe for abseil
# Description: C++ Common Libraries

set -e

# Metadata
export PACKAGE_NAME="abseil"
export PACKAGE_VERSION="20260817.0"
export PACKAGE_SHA256="f7e05179df39c45434cad433f5783840bb3788ef322976f9138bc6b72b3a107d"
export PACKAGE_LICENSE="Apache-2.0"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="ffe57de4b2a1fdb34e9af9e5eb4da0820830145e7ce3d11316e4700c6d20c1ff"

# Derived from version
export PACKAGE_URL="https://github.com/abseil/abseil-cpp/archive/refs/tags/${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

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

    # CMake args (common)
    local CMAKE_ARGS=(
        -DCMAKE_INSTALL_PREFIX="${PREFIX}"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_CXX_STANDARD=17
        -DBUILD_SHARED_LIBS=ON
        -DABSL_PROPAGATE_CXX_STD=ON
        -DABSL_ENABLE_INSTALL=ON
        -DABSL_BUILD_TEST_HELPERS=ON
        -DABSL_USE_EXTERNAL_GOOGLETEST=ON
        -DABSL_FIND_GOOGLETEST=ON
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

    # Install directly to final location
    cmake --install build

    echo "✓ ${PACKAGE_NAME} built successfully"
}
