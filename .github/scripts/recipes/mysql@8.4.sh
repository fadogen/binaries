#!/bin/bash
# Build recipe for mysql@8.4
# Description: Open source relational database management system

set -e

# Metadata
export PACKAGE_NAME="mysql@8.4"
export PACKAGE_VERSION="8.4.7"
export PACKAGE_SHA256="c0bf33a94cdb908f149aea0797affb1b139262ccf0e0b9787a17246207542e69"

# Derived from version (major.minor for download path)
MYSQL_MAJOR_MINOR="${PACKAGE_VERSION%.*}"
export PACKAGE_URL="https://cdn.mysql.com/Downloads/MySQL-${MYSQL_MAJOR_MINOR}/mysql-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies (common)
export DEPENDENCIES=(
    "abseil"
    "icu4c@78"
    "lz4"
    "openssl@3"
    "protobuf"
    "zlib"
    "zstd"
)

# Linux-specific dependencies
export DEPENDENCIES_LINUX=(
    "libedit"
    "libtirpc"
)

# Build dependencies (via Homebrew, not in bundle)
# Note: On Linux, uses_from_macos libs (curl) are provided by Homebrew/Linuxbrew
export BUILD_DEPENDENCIES=(
    "bison"
    "cmake"
    "curl"
    "pkgconf"
)

# Linux-specific build dependencies
export BUILD_DEPENDENCIES_LINUX=(
    "patchelf"
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

    # Platform-specific settings
    local HOMEBREW_OPT
    case "$OS_NAME" in
        Darwin)
            # Add headerpad for install_name_tool (CRITICAL for relocation on macOS)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            if [ -d "/opt/homebrew/opt" ]; then
                HOMEBREW_OPT="/opt/homebrew/opt"
            else
                HOMEBREW_OPT="/usr/local/opt"
            fi
            ;;
        *)
            # Linux: Include Linuxbrew paths
            local HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
            HOMEBREW_OPT="${HOMEBREW_PREFIX}/opt"
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

    # Find Homebrew bison (MySQL requires newer bison than system provides)
    local BISON_PATH="${HOMEBREW_OPT}/bison/bin/bison"
    if [ ! -f "$BISON_PATH" ]; then
        echo "Warning: Homebrew bison not found at $BISON_PATH, using system bison"
        BISON_PATH="$(command -v bison)"
    fi

    cd "${SOURCE_DIR}"

    # Apply patches
    echo "→ Applying patches..."

    # Patch 1: Remove Homebrew boost check (as per Homebrew formula)
    local PATCH1="${SCRIPT_DIR}/patches/mysql-remove-homebrew-boost-check.patch"
    patch -p1 < "$PATCH1"

    # Patch 2: Fix protobuf/abseil dependencies detection for custom PREFIX
    # Only needed on macOS (the patch is specific to APPLE)
    if [ "$OS_NAME" = "Darwin" ]; then
        local PATCH2="${SCRIPT_DIR}/patches/mysql-fix-protobuf-abseil-deps.patch"
        patch -p1 < "$PATCH2"
    fi

    echo "✓ Patches applied"

    # Linux-specific: Disable ABI checking (as per Homebrew formula)
    if [ "$OS_NAME" != "Darwin" ]; then
        echo "→ Disabling ABI check for Linux..."
        sed -i "s/RUN_ABI_CHECK 1/RUN_ABI_CHECK 0/" cmake/abi_check.cmake
        echo "✓ ABI check disabled"
    fi

    # Remove bundled libraries other than explicitly allowed (as per Homebrew formula)
    # boost and rapidjson must use bundled copy due to patches
    # lz4 is still needed due to xxhash.c used by mysqlgcs
    # Note: MySQL 8.4 doesn't have duktape (unlike 9.5)
    echo "→ Removing bundled libraries..."
    local KEEP="boost libbacktrace libcno lz4 rapidjson unordered_dense xxhash"
    for dir in extra/*; do
        if [ -d "$dir" ]; then
            local basename
            basename=$(basename "$dir")
            if ! echo "$KEEP" | grep -qw "$basename"; then
                echo "  Removing $dir"
                rm -rf "$dir"
            fi
        fi
    done
    echo "✓ Bundled libraries cleaned"

    # CMake args (common)
    # -DINSTALL_* are relative to CMAKE_INSTALL_PREFIX
    local CMAKE_ARGS=(
        -DCMAKE_INSTALL_PREFIX="${PREFIX}"
        -DCMAKE_PREFIX_PATH="${PREFIX}"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_FIND_FRAMEWORK=LAST
        -DCMAKE_VERBOSE_MAKEFILE=ON
        -DCOMPILATION_COMMENT=Fadogen
        -DINSTALL_DOCDIR=share/doc/mysql
        -DINSTALL_INCLUDEDIR=include/mysql
        -DINSTALL_INFODIR=share/info
        -DINSTALL_MANDIR=share/man
        -DINSTALL_MYSQLSHAREDIR=share/mysql
        -DINSTALL_PLUGINDIR=lib/plugin
        -DMYSQL_DATADIR="${PREFIX}/data"
        -DSYSCONFDIR="${PREFIX}/etc"
        -DBISON_EXECUTABLE="${BISON_PATH}"
        -DOPENSSL_ROOT_DIR="${PREFIX}"
        -DWITH_ICU="${PREFIX}"
        -DWITH_SYSTEM_LIBS=ON
        -DWITH_LZ4=system
        -DWITH_PROTOBUF=system
        -DWITH_SSL=system
        -DWITH_ZLIB=system
        -DWITH_ZSTD=system
        -DWITH_UNIT_TESTS=OFF
    )

    # Platform-specific CMake args
    case "$OS_NAME" in
        Darwin)
            # macOS: libedit is provided by the system
            CMAKE_ARGS+=(
                -DWITH_EDITLINE=system
            )
            ;;
        *)
            # Linux: libedit and curl are provided by Linuxbrew (BUILD_DEPENDENCIES)
            # Set RPATH so binaries can find shared libs at runtime
            CMAKE_ARGS+=(
                -DWITH_EDITLINE=system
                -DWITH_CURL=system
                -DCMAKE_BUILD_RPATH="${PREFIX}/lib"
                -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"
                -DCMAKE_EXE_LINKER_FLAGS="-L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"
                -DCMAKE_SHARED_LINKER_FLAGS="-L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib"
            )
            ;;
    esac

    # Configure with CMake
    cmake -S . -B build "${CMAKE_ARGS[@]}"

    # Build
    cmake --build build --verbose -j"$NPROC"

    # Install directly to final location
    cmake --install build

    # Remove the tests directory (as per Homebrew formula)
    rm -rf "${PREFIX}/mysql-test"

    # Fix up the control script and link into bin (as per Homebrew formula)
    if [ -f "${PREFIX}/support-files/mysql.server" ]; then
        case "$OS_NAME" in
            Darwin)
                sed -i '' 's|^PATH="\(.*\)"|PATH="\1:'"${PREFIX}"'/bin"|' "${PREFIX}/support-files/mysql.server"
                ;;
            *)
                sed -i 's|^PATH="\(.*\)"|PATH="\1:'"${PREFIX}"'/bin"|' "${PREFIX}/support-files/mysql.server"
                ;;
        esac
        ln -sf "${PREFIX}/support-files/mysql.server" "${PREFIX}/bin/mysql.server"
    fi

    # Install my.cnf that binds to 127.0.0.1 by default (as per Homebrew formula)
    mkdir -p "${PREFIX}/etc"
    cat > "${PREFIX}/etc/my.cnf" <<'EOF'
# Default Fadogen MySQL server config
[mysqld]
# Only allow connections from localhost
bind-address = 127.0.0.1
mysqlx-bind-address = 127.0.0.1
EOF

    echo "✓ ${PACKAGE_NAME} built successfully"
}
