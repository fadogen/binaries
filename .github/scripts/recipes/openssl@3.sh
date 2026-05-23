#!/bin/bash
# Build recipe for openssl
# Description: Cryptography and SSL/TLS toolkit

set -e

# Metadata
export PACKAGE_NAME="openssl@3"
export PACKAGE_VERSION="3.6.2"
export PACKAGE_SHA256="aaf51a1fe064384f811daeaeb4ec4dce7340ec8bd893027eee676af31e83a04f"

# Derived from version
export PACKAGE_URL="https://github.com/openssl/openssl/releases/download/openssl-${PACKAGE_VERSION}/openssl-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "ca-certificates"
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

    # Detect target based on OS and architecture
    local OPENSSL_TARGET
    local ARCH
    ARCH="$(uname -m)"

    local EXTRA_ARGS=""
    case "$(uname)" in
        Darwin)
            if [ "$ARCH" = "arm64" ]; then
                OPENSSL_TARGET="darwin64-arm64-cc"
            else
                OPENSSL_TARGET="darwin64-x86_64-cc"
            fi
            EXTRA_ARGS="enable-ec_nistp_64_gcc_128"
            ;;
        Linux)
            if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
                OPENSSL_TARGET="linux-aarch64"
            else
                OPENSSL_TARGET="linux-x86_64"
            fi
            # On Linux, pass flags to Configure (as Homebrew does)
            EXTRA_ARGS="$CPPFLAGS $LDFLAGS"
            ;;
        *)
            echo "Unsupported OS: $(uname)"
            exit 1
            ;;
    esac

    echo "Using OpenSSL target: $OPENSSL_TARGET"

    # Configure
    # shellcheck disable=SC2086
    ./Configure \
        "$OPENSSL_TARGET" \
        --prefix="${PREFIX}" \
        --openssldir="${PREFIX}/etc/openssl@3" \
        --libdir=lib \
        no-ssl3 \
        no-ssl3-method \
        no-zlib \
        $EXTRA_ARGS

    # Build
    make -j"${NPROC}"

    # Install directly to final location
    make install_sw install_ssldirs

    echo "✓ ${PACKAGE_NAME} built successfully"
}

# Post-install: Link ca-certificates to OpenSSL
post_install() {
    local PREFIX="$1"

    echo "Linking ca-certificates to OpenSSL..."

    local ca_cert="${PREFIX}/share/ca-certificates/cacert.pem"

    if [ -f "$ca_cert" ]; then
        echo "  Found ca-certificates at: $ca_cert"
        ln -sf "../../share/ca-certificates/cacert.pem" "${PREFIX}/etc/openssl@3/cert.pem"
        echo "  → Created relative symlink at ${PREFIX}/etc/openssl@3/cert.pem"
    else
        echo "  ⚠ Warning: ca-certificates not found at $ca_cert"
    fi
}
