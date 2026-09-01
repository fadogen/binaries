#!/bin/bash
# Build recipe for readline
# Description: Library for command-line editing

set -e

# Metadata
export PACKAGE_NAME="readline"
export PACKAGE_VERSION="8.3.3"
export PACKAGE_SHA256="fe5383204467828cd495ee8d1d3c037a7eba1389c22bc6a041f627976f9061cc"
export PACKAGE_LICENSE="GPL-3.0-or-later"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="639d7870259e2a72c9c26af07c32f603b6140505d72bfa0f2ef903960373a7a9"

# Base version (without patch level)
READLINE_BASE_VERSION="${PACKAGE_VERSION%.*}"

# Derived from version
export PACKAGE_URL="https://ftpmirror.gnu.org/gnu/${PACKAGE_NAME}/${PACKAGE_NAME}-${READLINE_BASE_VERSION}.tar.gz"

# Patch checksums (001, 002, 003)
declare -a PATCH_CHECKSUMS=(
    "21f0a03106dbe697337cd25c70eb0edbaa2bdb6d595b45f83285cdd35bac84de"
    "e27364396ba9f6debf7cbaaf1a669e2b2854241ae07f7eca74ca8a8ba0c97472"
    "72dee13601ce38f6746eb15239999a7c56f8e1ff5eb1ec8153a1f213e4acdb29"
)

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

    cd "${SOURCE_DIR}"

    # Apply patches (readline 8.3.3 = 8.3 + patches 001-003)
    echo "→ Applying patches..."
    local PATCH_LEVEL="${PACKAGE_VERSION##*.}"
    local BASE_SHORT="${READLINE_BASE_VERSION//./}"

    for i in $(seq 1 "$PATCH_LEVEL"); do
        local PATCH_NUM
        PATCH_NUM=$(printf "%03d" "$i")
        local PATCH_URL="https://ftpmirror.gnu.org/gnu/${PACKAGE_NAME}/${PACKAGE_NAME}-${READLINE_BASE_VERSION}-patches/${PACKAGE_NAME}${BASE_SHORT}-${PATCH_NUM}"

        # download_package caches, verifies and retries. ftpmirror.gnu.org
        # redirects to a random mirror and some of them answer 502, so the
        # retries matter here.
        local PATCH_FILE
        PATCH_FILE=$(download_package "$PATCH_URL" "${PATCH_CHECKSUMS[$((i-1))]}") || {
            echo "✗ Patch ${PATCH_NUM} could not be fetched or verified"
            return 1
        }

        # Apply patch (-p0 means strip 0 path components)
        patch -p0 < "$PATCH_FILE"
    done
    echo "✓ ${PATCH_LEVEL} patches applied"

    # Configure with ncurses support
    ./configure \
        --prefix="${PREFIX}" \
        --with-curses

    # Build (with ncurses linking for shared library)
    make -j"$NPROC" SHLIB_LIBS=-lcurses

    # Install directly to final location
    make install SHLIB_LIBS=-lcurses

    echo "✓ ${PACKAGE_NAME} built successfully"
}
