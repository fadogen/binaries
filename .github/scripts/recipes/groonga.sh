#!/bin/bash
# Build recipe for groonga
# Description: Fulltext search engine and column store

set -e

# Metadata
export PACKAGE_NAME="groonga"
export PACKAGE_VERSION="16.1.0"
export PACKAGE_SHA256="e10370308607bc7b499f0ab880c4f97dd2ad89f85edcf1d2b534e301ae3fb7b3"

# Derived from version
export PACKAGE_URL="https://github.com/groonga/groonga/releases/download/v${PACKAGE_VERSION}/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"

# groonga-normalizer-mysql resource
NORMALIZER_VERSION="1.3.0"
NORMALIZER_SHA256="693c24eff9ba95cd498ba28f8d5826843caec347b5aa6976e565e69535b44147"

# Runtime dependencies (bundled)
export DEPENDENCIES=(
    "lz4"
    "mecab"
    "mecab-ipadic"
    "msgpack"
    "onigmo"
    "simdjson"
    "zlib"
    "zstd"
)

# Build dependencies (via Homebrew, not in bundle)
# libedit is uses_from_macos in Homebrew (system on macOS, Linuxbrew on Linux)
export BUILD_DEPENDENCIES=(
    "cmake"
    "libedit"
    "pkgconf"
)

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect OS
    local OS_NAME
    OS_NAME="$(uname)"

    # Dependencies are installed in $PREFIX
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
    export CPPFLAGS="-I${PREFIX}/include"

    # Platform-specific settings
    case "$OS_NAME" in
        Darwin)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            ;;
        *)
            # Linux: Include Linuxbrew paths for uses_from_macos libs (libedit)
            local HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
            export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${HOMEBREW_PREFIX}/lib/pkgconfig"
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

    # Remove bundled libraries but keep files needed by build scripts
    echo "→ Removing bundled libraries..."
    for dir in vendor/*; do
        case "$(basename "$dir")" in
            CMakeLists.txt|mecab|mruby|plugins) ;;
            *) rm -rf "$dir" ;;
        esac
    done

    # CMake args (matching Homebrew formula)
    # Explicitly disable features to avoid opportunistic linkage
    local CMAKE_ARGS=(
        -DCMAKE_INSTALL_PREFIX="${PREFIX}"
        -DCMAKE_PREFIX_PATH="${PREFIX}"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_SYSCONFDIR="${PREFIX}/etc"
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON
    )

    # Linux: Add RPATH so linker finds shared libs during build and at runtime
    if [[ "$OS_NAME" != "Darwin" ]]; then
        CMAKE_ARGS+=(
            -DCMAKE_BUILD_RPATH="${PREFIX}/lib"
            -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
            -DCMAKE_EXE_LINKER_FLAGS="-L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"
            -DCMAKE_SHARED_LINKER_FLAGS="-L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"
        )
    fi

    CMAKE_ARGS+=(
        -DGRN_WITH_BASE64=no
        -DGRN_WITH_BUNDLED_ONIGMO=OFF
        -DGRN_WITH_CURL=no
        -DGRN_WITH_FAISS=no
        -DGRN_WITH_H3=no
        -DGRN_WITH_KYTEA=no
        -DGRN_WITH_LIBEDIT=system
        -DGRN_WITH_LLAMA_CPP=no
        -DGRN_WITH_LIBSTEMMER=no
        -DGRN_WITH_LZ4=system
        -DGRN_WITH_MECAB=yes
        -DGRN_WITH_MESSAGE_PACK=system
        -DGRN_WITH_SIMDJSON=system
        -DGRN_WITH_XSIMD=no
        -DGRN_WITH_XXHASH=no
        -DGRN_WITH_ZEROMQ=no
        -DGRN_WITH_ZLIB=yes
        -DGRN_WITH_ZSTD=system
        -DGroongalz4_FIND_QUIETLY=ON
    )

    # Configure with CMake
    cmake -S . -B _build "${CMAKE_ARGS[@]}"

    # Build
    cmake --build _build -j"$NPROC"

    # Install
    cmake --install _build

    # Build and install groonga-normalizer-mysql resource
    echo "→ Building groonga-normalizer-mysql ${NORMALIZER_VERSION}..."

    # Download and extract normalizer
    local NORMALIZER_URL="https://github.com/groonga/groonga-normalizer-mysql/releases/download/v${NORMALIZER_VERSION}/groonga-normalizer-mysql-${NORMALIZER_VERSION}.tar.gz"
    curl -fsSL "$NORMALIZER_URL" -o normalizer.tar.gz

    # Verify checksum
    echo "${NORMALIZER_SHA256}  normalizer.tar.gz" | shasum -a 256 -c -

    tar xzf normalizer.tar.gz
    cd "groonga-normalizer-mysql-${NORMALIZER_VERSION}"

    # Ensure groonga tools are in PATH
    export PATH="${PREFIX}/bin:${PATH}"

    # Configure normalizer with CMake
    local NORMALIZER_CMAKE_ARGS=(
        -DCMAKE_INSTALL_PREFIX="${PREFIX}"
        -DCMAKE_PREFIX_PATH="${PREFIX}"
        -DCMAKE_BUILD_TYPE=Release
    )

    # Linux: Add RPATH for normalizer too
    if [[ "$OS_NAME" != "Darwin" ]]; then
        NORMALIZER_CMAKE_ARGS+=(
            -DCMAKE_BUILD_RPATH="${PREFIX}/lib"
            -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
            -DCMAKE_EXE_LINKER_FLAGS="-L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"
            -DCMAKE_SHARED_LINKER_FLAGS="-L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"
        )
    fi

    cmake -S . -B _build "${NORMALIZER_CMAKE_ARGS[@]}"

    # Build and install normalizer
    cmake --build _build -j"$NPROC"
    cmake --install _build

    echo "✓ ${PACKAGE_NAME} built successfully"
}
