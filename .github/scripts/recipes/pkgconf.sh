#!/bin/bash
# Build recipe for pkgconf
# Description: Package compiler and linker metadata toolkit

set -e

# Metadata
export PACKAGE_NAME="pkgconf"
export PACKAGE_VERSION="2.5.1"
export PACKAGE_SHA256="cd05c9589b9f86ecf044c10a2269822bc9eb001eced2582cfffd658b0a50c243"

# Derived from version
export PACKAGE_URL="https://distfiles.ariadne.space/${PACKAGE_NAME}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.xz"

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

    # Build pkg-config search path
    local PC_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"

    # Configure
    ./configure \
        --prefix="${PREFIX}" \
        --disable-silent-rules \
        --with-pkg-config-dir="${PC_PATH}" \
        --with-system-includedir="/usr/include" \
        --with-system-libdir="/usr/lib"

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    # Create pkg-config symlink for compatibility
    ln -sf pkgconf "${PREFIX}/bin/pkg-config"
    if [ -f "${PREFIX}/share/man/man1/pkgconf.1" ]; then
        ln -sf pkgconf.1 "${PREFIX}/share/man/man1/pkg-config.1"
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}
