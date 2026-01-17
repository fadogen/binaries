#!/bin/bash
# Build recipe for gettext
# Description: GNU internationalization (i18n) and localization (l10n) library

set -e

# Metadata
export PACKAGE_NAME="gettext"
export PACKAGE_VERSION="0.26"
export PACKAGE_SHA256="39acf4b0371e9b110b60005562aace5b3631fed9b1bb9ecccfc7f56e58bb1d7f"

# Derived from version
export PACKAGE_URL="https://ftpmirror.gnu.org/gnu/${PACKAGE_NAME}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies (common)
export DEPENDENCIES=(
    "libunistring"
)

# Linux-specific dependencies
export DEPENDENCIES_LINUX=(
    "acl"
    "libxml2"
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

    # Workaround for newer Clang (macOS specific)
    if [ "$OS_NAME" = "Darwin" ]; then
        export CFLAGS="-Wno-incompatible-function-pointer-types"
        # macOS iconv workaround for Sequoia+
        export am_cv_func_iconv_works="yes"
    fi

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

    # Configure args (common)
    local CONFIGURE_ARGS=(
        --prefix="${PREFIX}"
        --with-libunistring-prefix="${PREFIX}"
        --disable-silent-rules
        --with-included-glib
        --with-included-libcroco
        --with-emacs
        --disable-java
        --disable-csharp
        --without-git
        --without-cvs
        --without-xz
    )

    # Platform-specific configure args
    if [ "$OS_NAME" = "Darwin" ]; then
        # Ship libintl.h on macOS (glibc provides it on Linux)
        CONFIGURE_ARGS+=(--with-included-gettext)
    else
        # Linux: link with system libxml2
        CONFIGURE_ARGS+=(--with-libxml2-prefix="${PREFIX}")
    fi

    # Configure
    ./configure "${CONFIGURE_ARGS[@]}"

    # Build (parallel)
    make -j"$NPROC"

    # Install directly to final location (non-parallel as per Homebrew formula)
    make install

    echo "✓ ${PACKAGE_NAME} built successfully"
}
