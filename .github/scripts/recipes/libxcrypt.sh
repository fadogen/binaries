#!/bin/bash
# Build recipe for libxcrypt
# Description: Extended crypt library for descrypt, md5crypt, bcrypt, and others

set -e

# Metadata
export PACKAGE_NAME="libxcrypt"
export PACKAGE_VERSION="4.5.2"
export PACKAGE_SHA256="71513a31c01a428bccd5367a32fd95f115d6dac50fb5b60c779d5c7942aec071"

# Derived from version
export PACKAGE_URL="https://github.com/besser82/${PACKAGE_NAME}/releases/download/v${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.xz"

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

    # Configure (matching Homebrew options)
    ./configure \
        --prefix="${PREFIX}" \
        --disable-static \
        --disable-obsolete-api \
        --disable-xcrypt-compat-files \
        --disable-failure-tokens \
        --disable-valgrind

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
