#!/bin/bash
# Build recipe for libxml2
# Description: GNOME XML library

set -e

# Metadata
export PACKAGE_NAME="libxml2"
export PACKAGE_VERSION="2.15.4"
export PACKAGE_SHA256="98087fd181d9070724f3fbc65c7377db03038eb92bd882374daff44940138821"
export PACKAGE_LICENSE="MIT"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="477fb4493d597ae0decb2e776392a720830f43e053b64af7b5d672b3eae1afd8"

# Derived from version
LIBXML2_MAJOR_MINOR="${PACKAGE_VERSION%.*}"
export PACKAGE_URL="https://download.gnome.org/sources/${PACKAGE_NAME}/${LIBXML2_MAJOR_MINOR}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.xz"

# Runtime dependencies
export DEPENDENCIES=(
    "readline"
    "zlib"
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
    ./configure \
        --prefix="${PREFIX}" \
        --sysconfdir="${PREFIX}/etc" \
        --disable-silent-rules \
        --with-history \
        --with-legacy

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install

    # Fix hardcoded paths in xml2-config and pkgconfig
    local XML2_CONFIG="${PREFIX}/bin/xml2-config"
    local PC_FILE="${PREFIX}/lib/pkgconfig/libxml-2.0.pc"

    case "$OS_NAME" in
        Darwin)
            if [ -f "$XML2_CONFIG" ]; then
                sed -i '' "s|^prefix=.*|prefix=${PREFIX}|" "$XML2_CONFIG"
            fi
            if [ -f "$PC_FILE" ]; then
                sed -i '' "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE"
            fi
            ;;
        *)
            if [ -f "$XML2_CONFIG" ]; then
                sed -i "s|^prefix=.*|prefix=${PREFIX}|" "$XML2_CONFIG"
            fi
            if [ -f "$PC_FILE" ]; then
                sed -i "s|^prefix=.*|prefix=${PREFIX}|" "$PC_FILE"
            fi
            ;;
    esac

    echo "✓ ${PACKAGE_NAME} built successfully"
}
