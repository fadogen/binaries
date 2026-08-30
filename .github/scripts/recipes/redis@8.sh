#!/bin/bash
# Build recipe for redis@8
# Description: Persistent key-value database, with built-in net interface

set -e

# Metadata
export PACKAGE_NAME="redis@8"
export PACKAGE_VERSION="8.10.1"
export PACKAGE_SHA256="60166c95ab7aedaa9dfe516de685be0a4dd87be95ded59ba429df14c13f1b663"

# Derived from version
export PACKAGE_URL="https://download.redis.io/releases/redis-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "openssl@3"
)

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Dependencies are installed in $PREFIX (parent_prefix logic)
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"

    # Platform-specific LDFLAGS
    case "$(uname)" in
        Darwin)
            # Add headerpad for install_name_tool (CRITICAL for relocation on macOS)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            ;;
        *)
            export LDFLAGS="-L${PREFIX}/lib"
            ;;
    esac

    # Detect number of CPU cores (cross-platform)
    if command -v nproc >/dev/null 2>&1; then
        NPROC=$(nproc)
    elif command -v sysctl >/dev/null 2>&1; then
        NPROC=$(sysctl -n hw.ncpu)
    else
        NPROC=4
    fi

    cd "${SOURCE_DIR}"

    # Build + install with a single make call (matches Homebrew formula).
    # BUILD_TLS=yes enables TLS support with OpenSSL.
    # LD=cc is required on macOS: redis' tests/modules/Makefile links .so via
    # $(LD), which falls back to bare `ld` on Darwin and can't parse the
    # `-Wl,-headerpad_max_install_names` syntax in LDFLAGS. On Linux the
    # modules Makefile forces LD=gcc internally so this is a no-op there.
    make -j"${NPROC}" install \
        PREFIX="${PREFIX}" \
        CC="${CC:-cc}" \
        LD="${CC:-cc}" \
        BUILD_TLS=yes

    echo "✓ ${PACKAGE_NAME} built successfully"
}
