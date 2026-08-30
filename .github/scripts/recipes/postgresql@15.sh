#!/bin/bash
# Build recipe for postgresql@15
# Description: Object-relational database system

set -e

# Metadata
export PACKAGE_NAME="postgresql@15"
export PACKAGE_VERSION="15.19"
export PACKAGE_SHA256="e1a64a87a46b825b88c082e4518161a47aab53c45694964f8ba1df28f7859f89"
export PACKAGE_LICENSE="PostgreSQL"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="7f7611bc3a29edd8f41e9b18aec878f9b7c4c8d138a20ca09adca5f76be3f5e1"

# Derived from version
export PACKAGE_URL="https://ftp.postgresql.org/pub/source/v${PACKAGE_VERSION}/postgresql-${PACKAGE_VERSION}.tar.bz2"

# Runtime dependencies (common)
# Note: libxml2, libxslt, openldap, perl, zlib are "uses_from_macos" (system-provided)
export DEPENDENCIES=(
    "icu4c@78"
    "krb5"
    "lz4"
    "openssl@3"
    "readline"
    "zstd"
)

# macOS-specific dependencies
export DEPENDENCIES_MACOS=(
    "gettext"
)

# Linux-specific dependencies
export DEPENDENCIES_LINUX=(
    "linux-pam"
    "util-linux"
)

# Build dependencies (installed via Homebrew)
# Note: v15 doesn't use docbook for documentation
# On Linux, uses_from_macos libs are provided by Homebrew/Linuxbrew
export BUILD_DEPENDENCIES=(
    "pkgconf"
    "gettext"
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
    local CONFIGURE_ARGS=(
        --prefix="${PREFIX}"
        --datadir="${PREFIX}/share/postgresql"
        --libdir="${PREFIX}/lib"
        --includedir="${PREFIX}/include"
        --sysconfdir="${PREFIX}/etc"
        --docdir="${PREFIX}/share/doc/postgresql"
        --enable-nls
        --enable-thread-safety
        --with-gssapi
        --with-icu
        --with-ldap
        --with-libxml
        --with-libxslt
        --with-lz4
        --with-zstd
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

    # Build (with path workaround for Makefile.global.in bug)
    # See https://github.com/Homebrew/homebrew-core/issues/62930#issuecomment-709411789
    make -j"$NPROC" \
        pkglibdir="${PREFIX}/lib/postgresql" \
        pkgincludedir="${PREFIX}/include/postgresql" \
        includedir_server="${PREFIX}/include/postgresql/server"

    # Install directly to final location
    make install-world \
        datadir="${PREFIX}/share/postgresql" \
        libdir="${PREFIX}/lib" \
        pkglibdir="${PREFIX}/lib/postgresql" \
        includedir="${PREFIX}/include" \
        pkgincludedir="${PREFIX}/include/postgresql" \
        includedir_server="${PREFIX}/include/postgresql/server" \
        includedir_internal="${PREFIX}/include/postgresql/internal"

    echo "✓ ${PACKAGE_NAME} built successfully"
}
