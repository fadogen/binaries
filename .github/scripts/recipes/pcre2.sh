#!/bin/bash
# Build recipe for pcre2
# Description: Perl compatible regular expressions library with a new API

set -e

# Metadata
export PACKAGE_NAME="pcre2"
export PACKAGE_VERSION="10.47"
export PACKAGE_SHA256="47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7"
export PACKAGE_LICENSE="BSD-3-Clause"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="b469d38bf6abd31a1ccd8ce940fd4a416df4eb5df3da1d215066e7f85b99d7a8"

# Derived from version
export PACKAGE_URL="https://github.com/PCRE2Project/${PACKAGE_NAME}/releases/download/${PACKAGE_NAME}-${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.bz2"

# No runtime dependencies (uses_from_macos: bzip2, zlib)
export DEPENDENCIES=()

# Build dependencies (uses_from_macos on macOS, Linuxbrew on Linux)
export BUILD_DEPENDENCIES=(
    "bzip2"
)

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect OS
    local OS_NAME
    OS_NAME="$(uname)"

    # Platform-specific flags
    case "$OS_NAME" in
        Darwin)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            export CPPFLAGS="-I${PREFIX}/include"
            ;;
        *)
            # Linux: Include Linuxbrew paths for uses_from_macos libs (bzip2)
            local HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
            export LDFLAGS="-L${PREFIX}/lib -L${HOMEBREW_PREFIX}/lib"
            export CPPFLAGS="-I${PREFIX}/include -I${HOMEBREW_PREFIX}/include"
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

    # Configure args (common)
    local CONFIGURE_ARGS=(
        --prefix="${PREFIX}"
        --disable-dependency-tracking
        --enable-pcre2-16
        --enable-pcre2-32
        --enable-pcre2grep-libz
        --enable-pcre2grep-libbz2
        --enable-jit
    )

    # macOS only: enable libedit support for pcre2test
    if [ "$OS_NAME" = "Darwin" ]; then
        CONFIGURE_ARGS+=(--enable-pcre2test-libedit)
    fi

    # Configure
    ./configure "${CONFIGURE_ARGS[@]}"

    # Build
    make -j"$NPROC"

    # Install
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
