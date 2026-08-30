#!/bin/bash
# Build recipe for mecab
# Description: Yet another part-of-speech and morphological analyzer

set -e

# Metadata
export PACKAGE_NAME="mecab"
export PACKAGE_VERSION="0.996"
export PACKAGE_SHA256="e073325783135b72e666145c781bb48fada583d5224fb2490fb6c1403ba69c59"
export PACKAGE_LICENSE="GPL-2.0-only OR LGPL-2.1-only OR BSD-3-Clause"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="b350c550d1f63f9e392994eb4ba1a78e95cc3695c760bc9f95ff332aa3150fcb"

# Derived from version (Debian pool format)
export PACKAGE_URL="https://deb.debian.org/debian/pool/main/m/${PACKAGE_NAME}/${PACKAGE_NAME}_${PACKAGE_VERSION}.orig.tar.gz"

# No runtime dependencies
export DEPENDENCIES=()

# No build dependencies
export BUILD_DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect OS
    local OS_NAME
    OS_NAME="$(uname)"

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

    # Configure args
    local CONFIGURE_ARGS=(
        --prefix="${PREFIX}"
        --sysconfdir="${PREFIX}/etc"
        --disable-dependency-tracking
    )

    # Help old config scripts identify arm64 linux
    if [ "$OS_NAME" = "Linux" ]; then
        local ARCH
        ARCH="$(uname -m)"
        if [ "$ARCH" = "aarch64" ]; then
            CONFIGURE_ARGS+=(--build=aarch64-unknown-linux-gnu)
        fi
    fi

    # Configure
    ./configure "${CONFIGURE_ARGS[@]}"

    # Build
    make -j"$NPROC"

    # Install
    make install

    # Fix dictionary paths to use our PREFIX
    # mecab-config
    if [ -f "${PREFIX}/bin/mecab-config" ]; then
        case "$OS_NAME" in
            Darwin) sed -i '' "s|${PREFIX}/lib/mecab/dic|${PREFIX}/lib/mecab/dic|g" "${PREFIX}/bin/mecab-config" ;;
            *) sed -i "s|${PREFIX}/lib/mecab/dic|${PREFIX}/lib/mecab/dic|g" "${PREFIX}/bin/mecab-config" ;;
        esac
    fi

    # mecabrc
    if [ -f "${PREFIX}/etc/mecabrc" ]; then
        case "$OS_NAME" in
            Darwin) sed -i '' "s|${PREFIX}/lib/mecab/dic|${PREFIX}/lib/mecab/dic|g" "${PREFIX}/etc/mecabrc" ;;
            *) sed -i "s|${PREFIX}/lib/mecab/dic|${PREFIX}/lib/mecab/dic|g" "${PREFIX}/etc/mecabrc" ;;
        esac
    fi

    # Create dic directory
    mkdir -p "${PREFIX}/lib/mecab/dic"

    echo "✓ ${PACKAGE_NAME} built successfully"
}
