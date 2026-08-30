#!/bin/bash
# Build recipe for util-linux
# Description: Collection of Linux utilities

set -e

# Metadata
export PACKAGE_NAME="util-linux"
export PACKAGE_VERSION="2.42.2"
export PACKAGE_SHA256="03a05d3adf9602ef128f2da05b84b3205ce60c351e5737c0370f74000679ce8a"
export PACKAGE_LICENSE="BSD-3-Clause AND BSD-4-Clause-UC AND GPL-2.0-only AND GPL-2.0-or-later AND GPL-3.0-or-later AND LGPL-2.1-or-later AND LicenseRef-Homebrew-public-domain"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="4c2174c9150d94ef5af9366406471c144bb8593fd3a3bfa1784d4c59071652e3"

# Major.minor for URL path
UTIL_LINUX_MAJOR_MINOR="${PACKAGE_VERSION%.*}"

# Derived from version
export PACKAGE_URL="https://mirrors.edge.kernel.org/pub/linux/utils/${PACKAGE_NAME}/v${UTIL_LINUX_MAJOR_MINOR}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.xz"

# Runtime dependencies (common)
export DEPENDENCIES=(
    "zlib"
    "libxcrypt"
)

# macOS-specific dependencies
export DEPENDENCIES_MACOS=(
    "gettext"
)

# Linux-specific dependencies
export DEPENDENCIES_LINUX=(
    "readline"
)

# Build dependencies
export BUILD_DEPENDENCIES=(
    "autoconf"
    "automake"
    "gettext"
    "gtk-doc"
    "libtool"
    "pkgconf"
)

# Patch URL and checksum
PATCH_URL="https://github.com/util-linux/util-linux/commit/d22edc2f100eb8dd83d3515758565cb73b0d2eed.patch?full_index=1"
PATCH_SHA256="2fb01154faa3fd8b0fce27eb88049ed9c8f839e706e412399c19c087f7f3b5e1"

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

    # Platform-specific LDFLAGS and CFLAGS
    case "$OS_NAME" in
        Darwin)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            # Support very old ncurses used on macOS 13 and earlier
            local MACOS_VERSION
            MACOS_VERSION="$(sw_vers -productVersion | cut -d. -f1)"
            if [ "$MACOS_VERSION" -le 13 ]; then
                export CFLAGS="-D_XOPEN_SOURCE_EXTENDED"
            fi
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

    # Download and apply patch
    echo "→ Downloading and applying patch..."
    local PATCH_FILE="${DOWNLOADS_DIR}/util-linux-bits.patch"
    if [ ! -f "$PATCH_FILE" ]; then
        curl -fSL -o "$PATCH_FILE" "$PATCH_URL"
    fi

    # Verify patch checksum
    if command -v sha256sum >/dev/null 2>&1; then
        echo "$PATCH_SHA256  $PATCH_FILE" | sha256sum -c - || {
            echo "✗ Patch checksum verification failed"
            return 1
        }
    else
        echo "$PATCH_SHA256  $PATCH_FILE" | shasum -a 256 -c - || {
            echo "✗ Patch checksum verification failed"
            return 1
        }
    fi

    # Apply patch
    patch -p1 < "$PATCH_FILE" || true  # May already be applied

    # Run autoreconf (required after patching)
    echo "→ Running autoreconf..."
    autoreconf --force --install --verbose

    # Configure args (common)
    local CONFIGURE_ARGS=(
        --prefix="${PREFIX}"
        --disable-silent-rules
        --disable-asciidoc
    )

    # Platform-specific configure args
    if [ "$OS_NAME" = "Darwin" ]; then
        CONFIGURE_ARGS+=(
            --disable-bits
            --disable-ipcs
            --disable-ipcrm
            --disable-wall
            --disable-liblastlog2
            --disable-libmount
            --enable-libuuid
        )
    else
        # Linux-specific options
        CONFIGURE_ARGS+=(
            --disable-use-tty-group
            --disable-kill
            --without-systemd
            --disable-chfn-chsh
            --disable-login
            --disable-su
            --disable-runuser
            --disable-makeinstall-chown
            --disable-makeinstall-setuid
            --without-python
        )
    fi

    # Configure
    ./configure "${CONFIGURE_ARGS[@]}"

    # Build
    make -j"$NPROC"

    # Install (with LDFLAGS=-lm on Linux)
    if [ "$OS_NAME" = "Linux" ]; then
        make install LDFLAGS=-lm
    else
        make install
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}
