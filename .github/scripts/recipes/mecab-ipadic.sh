#!/bin/bash
# Build recipe for mecab-ipadic
# Description: IPA dictionary compiled for MeCab

set -e

# Metadata
export PACKAGE_NAME="mecab-ipadic"
export PACKAGE_VERSION="2.7.0-20070801"
export PACKAGE_SHA256="b62f527d881c504576baed9c6ef6561554658b175ce6ae0096a60307e49e3523"

# Derived from version (Debian pool format)
export PACKAGE_URL="https://deb.debian.org/debian/pool/main/m/${PACKAGE_NAME}/${PACKAGE_NAME}_${PACKAGE_VERSION}+main.orig.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "mecab"
)

# No build dependencies
export BUILD_DEPENDENCIES=()

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

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
        --disable-debug \
        --disable-dependency-tracking \
        --prefix="${PREFIX}" \
        --with-charset=utf8 \
        --with-dicdir="${PREFIX}/lib/mecab/dic/ipadic"

    # Build
    make -j"$NPROC"

    # Install
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
