#!/bin/bash
# Build recipe for linux-pam
# Description: Pluggable Authentication Modules for Linux

set -e

# Metadata
export PACKAGE_NAME="linux-pam"
export PACKAGE_VERSION="1.7.2"
export PACKAGE_SHA256="3d86b6383fb5fd9eb9578d2cd47d92801191f4bf3f9bc61419bfefc8aa1e531a"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="2b3d6f9c790e2d1163a68095113b27105c8dfe9ac6450dfee1a9d39d7686f0d8"

# Derived from version (note: archive uses Linux-PAM capitalization)
export PACKAGE_URL="https://github.com/${PACKAGE_NAME}/${PACKAGE_NAME}/releases/download/v${PACKAGE_VERSION}/Linux-PAM-${PACKAGE_VERSION}.tar.xz"

# Runtime dependencies
export DEPENDENCIES=(
    "libnsl"
    "libtirpc"
    "libxcrypt"
)

# Build dependencies
export BUILD_DEPENDENCIES=(
    "meson"
    "ninja"
    "pkgconf"
)

# Linux only
export LINUX_ONLY=true

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Check if running on Linux
    if [ "$(uname)" != "Linux" ]; then
        echo "⚠ ${PACKAGE_NAME} is Linux only, skipping on $(uname)"
        return 0
    fi

    # Check for meson and ninja
    if ! command -v meson >/dev/null 2>&1; then
        echo "✗ meson is required but not found. Install with: apt install meson"
        return 1
    fi
    if ! command -v ninja >/dev/null 2>&1; then
        echo "✗ ninja is required but not found. Install with: apt install ninja-build"
        return 1
    fi

    # Set environment
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"
    export LDFLAGS="-L${PREFIX}/lib"

    cd "${SOURCE_DIR}"

    # Configure with meson
    meson setup build \
        --prefix="${PREFIX}" \
        --libdir="${PREFIX}/lib" \
        --sysconfdir="${PREFIX}/etc" \
        -Dsecuredir="${PREFIX}/lib/security"

    # Build with meson/ninja
    meson compile -C build --verbose

    # Install
    meson install -C build

    echo "✓ ${PACKAGE_NAME} built successfully"
}
