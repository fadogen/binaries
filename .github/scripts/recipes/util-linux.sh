#!/bin/bash
# Build recipe for util-linux
# Description: Collection of Linux utilities

set -e

# Metadata
export PACKAGE_NAME="util-linux"
export PACKAGE_VERSION="2.41.3"
export PACKAGE_SHA256="3330d873f0fceb5560b89a7dc14e4f3288bbd880e96903ed9b50ec2b5799e58b"

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
    "pkgconf"
    "gettext"
)

# Patch URL and checksum
PATCH_URL="https://github.com/util-linux/util-linux/commit/45f943a4b36f59814cf5a735e4975f2252afac26.patch?full_index=1"
PATCH_SHA256="b372a7578ff397787f37e1aa1c03c8299c9b3e3f7ab8620c4af68c93ab2103b5"

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
