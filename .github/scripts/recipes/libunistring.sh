#!/bin/bash
# Build recipe for libunistring
# Description: C string library for manipulating Unicode strings

set -e

# Metadata
export PACKAGE_NAME="libunistring"
export PACKAGE_VERSION="1.4.1"
export PACKAGE_SHA256="12542ad7619470efd95a623174dcd4b364f2483caf708c6bee837cb53a54cb9d"

# Derived from version
export PACKAGE_URL="https://ftpmirror.gnu.org/gnu/${PACKAGE_NAME}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Dependencies are installed in $PREFIX (parent_prefix logic)
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"
    # Add headerpad for install_name_tool (CRITICAL for relocation)
    export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"

    cd "${SOURCE_DIR}"

    # macOS iconv workaround for Sonoma and later
    # https://savannah.gnu.org/bugs/?65686
    export am_cv_func_iconv_works="yes"

    # Configure
    ./configure \
        --prefix="${PREFIX}" \
        --disable-silent-rules

    # Build
    make -j"$(sysctl -n hw.ncpu)"

    # Skip tests on macOS (iconv issues on Sonoma+)
    # make check

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
