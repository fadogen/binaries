#!/bin/bash
# Build recipe for postgresql@18
# Description: Object-relational database system

set -e

# Metadata
export PACKAGE_NAME="postgresql@18"
export PACKAGE_VERSION="18.4"
export PACKAGE_SHA256="81a81ec695fb0c7901407defaa1d2f7973617154cf27ba74e3a7ab8e64436094"

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
# Note: On Linux, uses_from_macos libs are provided by Homebrew/Linuxbrew
export BUILD_DEPENDENCIES=(
    "docbook"
    "docbook-xsl"
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
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            # Fix 'libintl.h' file not found for extensions
            # Update config to fix GSSAPI function not found
            export LDFLAGS="-L${PREFIX}/lib -L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            export CPPFLAGS="-I${PREFIX}/include -I${PREFIX}/include"
            ;;
        *)
            # Linux: Include Homebrew/Linuxbrew paths for uses_from_macos libs
            local HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
            export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${HOMEBREW_PREFIX}/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/libxml2/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/libxslt/lib/pkgconfig:${HOMEBREW_PREFIX}/opt/openldap/lib/pkgconfig"
            export LDFLAGS="-L${PREFIX}/lib -L${HOMEBREW_PREFIX}/lib"
            export CPPFLAGS="-I${PREFIX}/include -I${HOMEBREW_PREFIX}/include"
            ;;
    esac

    # Set XML catalog for docbook (use Homebrew's catalog)
    # On macOS: /opt/homebrew/etc or /usr/local/etc
    # On Linux: /home/linuxbrew/.linuxbrew/etc
    if [ "$OS_NAME" = "Darwin" ]; then
        if [ -f "/opt/homebrew/etc/xml/catalog" ]; then
            export XML_CATALOG_FILES="/opt/homebrew/etc/xml/catalog"
        elif [ -f "/usr/local/etc/xml/catalog" ]; then
            export XML_CATALOG_FILES="/usr/local/etc/xml/catalog"
        fi
    else
        # Linux with Linuxbrew
        if [ -f "/home/linuxbrew/.linuxbrew/etc/xml/catalog" ]; then
            export XML_CATALOG_FILES="/home/linuxbrew/.linuxbrew/etc/xml/catalog"
        fi
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

    # Platform-specific source patching
    if [ "$OS_NAME" = "Darwin" ]; then
        # Modify Makefile.shlib to use correct install_name for dylibs
        echo "→ Patching Makefile.shlib for correct dylib paths..."
        sed -i '' "s|-install_name '\$(libdir)/|-install_name '${PREFIX}/lib/postgresql/|" src/Makefile.shlib
    fi

    # Configure args (common)
    local CONFIGURE_ARGS=(
        --prefix="${PREFIX}"
        --datadir="${PREFIX}/share/postgresql"
        --includedir="${PREFIX}/include/postgresql"
        --sysconfdir="${PREFIX}/etc"
        --docdir="${PREFIX}/share/doc/postgresql"
        --libdir="${PREFIX}/lib/postgresql"
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

    # Build
    make -j"$NPROC"

    # Install directly to final location
    make install-world \
        datadir="${PREFIX}/share/postgresql" \
        libdir="${PREFIX}/lib/postgresql" \
        includedir="${PREFIX}/include/postgresql"

    # Platform-specific post-install
    if [ "$OS_NAME" = "Darwin" ]; then
        # Restore Makefile.shlib for dependents
        local MAKEFILE="${PREFIX}/lib/postgresql/pgxs/src/Makefile.shlib"
        if [ -f "$MAKEFILE" ]; then
            sed -i '' "s|-install_name '${PREFIX}/lib/postgresql/|-install_name '\$(libdir)/|" "$MAKEFILE"
        fi
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}
