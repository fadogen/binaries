#!/bin/bash
# Build recipe for krb5
# Description: Network authentication protocol

set -e

# Metadata
export PACKAGE_NAME="krb5"
export PACKAGE_VERSION="1.22.1"
export PACKAGE_SHA256="1a8832b8cad923ebbf1394f67e2efcf41e3a49f460285a66e35adec8fa0053af"

# Derived from version (URL uses major.minor in path)
PACKAGE_VERSION_SHORT="${PACKAGE_VERSION%.*}"
export PACKAGE_URL="https://kerberos.org/dist/${PACKAGE_NAME}/${PACKAGE_VERSION_SHORT}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies (must be built first)
export DEPENDENCIES=(
    "openssl@3"
)

# Linux-specific dependencies
export DEPENDENCIES_LINUX=(
    "keyutils"
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

    # Change to src directory (krb5 builds from src/)
    cd "${SOURCE_DIR}/src"

    # Configure (matches Homebrew's std_configure_args + formula options)
    ./configure \
        --prefix="${PREFIX}" \
        --disable-debug \
        --disable-dependency-tracking \
        --disable-nls \
        --disable-silent-rules \
        --without-system-verto

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
