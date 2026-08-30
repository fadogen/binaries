#!/bin/bash
# Build recipe for zlib
# Description: General-purpose lossless data-compression library

set -e

# Metadata
export PACKAGE_NAME="zlib"
export PACKAGE_VERSION="1.3.2"
export PACKAGE_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
export PACKAGE_LICENSE="Zlib"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="513e21e1bdd4404e4b45e2924f91a0d2eaf46cb34966dccd636b51525be80b84"

# Derived from version
export PACKAGE_URL="https://zlib.net/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

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

    # Configure
    ./configure --prefix="${PREFIX}"

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    # Fix pkgconfig file to use correct prefix
    local PC_FILE="${PREFIX}/lib/pkgconfig/zlib.pc"
    if [ -f "$PC_FILE" ]; then
        case "$OS_NAME" in
            Darwin) sed -i '' "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE" ;;
            *) sed -i "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE" ;;
        esac
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}
