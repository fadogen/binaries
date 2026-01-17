#!/bin/bash
# Build recipe for postgresql@18
# Description: Object-relational database system

set -e

# Metadata
export PACKAGE_NAME="postgresql@18"
export PACKAGE_VERSION="18.1"
export PACKAGE_SHA256="ff86675c336c46e98ac991ebb306d1b67621ece1d06787beaade312c2c915d54"

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

# Build dependencies (installed via Homebrew on macOS, system packages on Linux)
export BUILD_DEPENDENCIES=(
    "docbook"
    "docbook-xsl"
    "pkgconf"
    "gettext"
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
            # Fix 'libintl.h' file not found for extensions
            # Update config to fix GSSAPI function not found
            export LDFLAGS="-L${PREFIX}/lib -L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            export CPPFLAGS="-I${PREFIX}/include -I${PREFIX}/include"
            ;;
        *)
            export LDFLAGS="-L${PREFIX}/lib"
            ;;
    esac

    # Set XML catalog for docbook (if available)
    if [ -f "/opt/homebrew/etc/xml/catalog" ]; then
        export XML_CATALOG_FILES="/opt/homebrew/etc/xml/catalog"
    elif [ -f "/usr/local/etc/xml/catalog" ]; then
        export XML_CATALOG_FILES="/usr/local/etc/xml/catalog"
    elif [ -f "${PREFIX}/etc/xml/catalog" ]; then
        export XML_CATALOG_FILES="${PREFIX}/etc/xml/catalog"
    elif [ -f "/etc/xml/catalog" ]; then
        export XML_CATALOG_FILES="/etc/xml/catalog"
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
