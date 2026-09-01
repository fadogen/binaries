#!/bin/bash
# Build recipe for libunistring
# Description: C string library for manipulating Unicode strings

set -e

# Metadata
export PACKAGE_NAME="libunistring"
export PACKAGE_VERSION="1.4.2"
export PACKAGE_SHA256="e82664b170064e62331962126b259d452d53b227bb4a93ab20040d846fec01d8"
export PACKAGE_LICENSE="GPL-2.0-or-later OR LGPL-3.0-or-later"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="47e15c61196660b5620a416bbae01a894b856ca6c712d66fe45c6aafaa617a4c"

# Derived from version
export PACKAGE_URL="https://ftp.gnu.org/gnu/${PACKAGE_NAME}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

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
            # macOS iconv workaround for Sonoma and later
            # https://savannah.gnu.org/bugs/?65686
            export am_cv_func_iconv_works="yes"
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

    # Configure
    ./configure \
        --prefix="${PREFIX}" \
        --disable-silent-rules

    # Build
    make -j"$NPROC"

    # Skip tests on macOS (iconv issues on Sonoma+)
    # make check

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
