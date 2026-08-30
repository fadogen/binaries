#!/bin/bash
# Build recipe for postgresql@14
# Description: Object-relational database system

set -e

# Metadata
export PACKAGE_NAME="postgresql@14"
export PACKAGE_VERSION="14.24"
export PACKAGE_SHA256="a7fa7ed3d558172355f51406097a7bd4f6b473be80f311ef7cda96bf383d8897"

# Derived from version
export PACKAGE_URL="https://ftp.postgresql.org/pub/source/v${PACKAGE_VERSION}/postgresql-${PACKAGE_VERSION}.tar.bz2"

# Runtime dependencies (common)
# Note: v14 doesn't have zstd or gettext support
# libxml2, libxslt, openldap, perl, zlib are "uses_from_macos" (system-provided)
export DEPENDENCIES=(
    "icu4c@78"
    "krb5"
    "lz4"
    "openssl@3"
    "readline"
)

# Linux-specific dependencies
export DEPENDENCIES_LINUX=(
    "linux-pam"
    "util-linux"
)

# Build dependencies (installed via Homebrew)
# On Linux, uses_from_macos libs are provided by Homebrew/Linuxbrew
export BUILD_DEPENDENCIES=(
    "pkgconf"
    "libxml2"
    "libxslt"
    "openldap"
    "perl"
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

    # Platform-specific LDFLAGS and paths
    case "$OS_NAME" in
        Darwin)
            # Add headerpad for install_name_tool (CRITICAL for relocation)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            ;;
        *)
            # Linux: Include Homebrew/Linuxbrew paths for uses_from_macos libs
            local HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
            export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${HOMEBREW_PREFIX}/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/libxml2/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/libxslt/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/openldap/lib/pkgconfig"
            export LDFLAGS="-L${PREFIX}/lib -L${HOMEBREW_PREFIX}/lib"
            export CPPFLAGS="-I${PREFIX}/include -I${HOMEBREW_PREFIX}/include"
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

    # Configure args (common)
    # Note: v14 doesn't support --with-zstd or --enable-nls
    local CONFIGURE_ARGS=(
        --prefix="${PREFIX}"
        --datadir="${PREFIX}/share/postgresql"
        --libdir="${PREFIX}/lib/postgresql"
        --includedir="${PREFIX}/include/postgresql"
        --disable-debug
        --enable-thread-safety
        --with-gssapi
        --with-icu
        --with-ldap
        --with-libxml
        --with-libxslt
        --with-lz4
        --with-openssl
        --with-pam
        --with-perl
        --with-uuid=e2fs
    )

    # Platform-specific configure args
    if [ "$OS_NAME" = "Darwin" ]; then
        CONFIGURE_ARGS+=(
            --with-bonjour
            --with-tcl
        )
    fi

    # Configure PostgreSQL
    ./configure "${CONFIGURE_ARGS[@]}"

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install-world \
        datadir="${PREFIX}/share/postgresql" \
        libdir="${PREFIX}/lib/postgresql" \
        pkglibdir="${PREFIX}/lib/postgresql" \
        includedir="${PREFIX}/include/postgresql" \
        pkgincludedir="${PREFIX}/include/postgresql" \
        includedir_server="${PREFIX}/include/postgresql/server" \
        includedir_internal="${PREFIX}/include/postgresql/internal"

    echo "✓ ${PACKAGE_NAME} built successfully"
}
