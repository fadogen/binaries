#!/bin/bash
# Build recipe for mariadb@11.8
# Description: Drop-in replacement for MySQL

set -e

# Metadata
export PACKAGE_NAME="mariadb@11.8"
export PACKAGE_VERSION="11.8.5"
export PACKAGE_SHA256="bcb7394569c08877c283e1649869504531bee8caafa30288f078e30d99fcb9f6"

# Derived from version
export PACKAGE_URL="https://archive.mariadb.org/mariadb-${PACKAGE_VERSION}/source/mariadb-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies (common)
export DEPENDENCIES=(
    "groonga"
    "lz4"
    "lzo"
    "openssl@3"
    "pcre2"
    "xz"
    "zlib"
    "zstd"
)

# Linux-specific dependencies
export DEPENDENCIES_LINUX=(
    "libedit"
    "linux-pam"
)

# Build dependencies (via Homebrew, not in bundle)
# Note: On Linux, uses_from_macos libs are provided by Homebrew/Linuxbrew
export BUILD_DEPENDENCIES=(
    "bison"
    "bzip2"
    "cmake"
    "fmt"
    "libedit"
    "libxml2"
    "ncurses"
    "pkgconf"
)

# macOS-specific build dependencies
export BUILD_DEPENDENCIES_MACOS=(
    "openjdk"
)

# Build function
build() {
    local PREFIX="$1"
    local SOURCE_DIR="$2"

    echo "Building ${PACKAGE_NAME} ${PACKAGE_VERSION}..."

    # Detect OS
    local OS_NAME
    OS_NAME="$(uname)"

    # Set PKG_CONFIG_PATH to find our dependencies
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"

    # Platform-specific settings
    local HOMEBREW_OPT
    case "$OS_NAME" in
        Darwin)
            # Add headerpad for install_name_tool (CRITICAL for relocation)
            export LDFLAGS="-L${PREFIX}/lib -Wl,-headerpad_max_install_names"
            if [ -d "/opt/homebrew/opt" ]; then
                HOMEBREW_OPT="/opt/homebrew/opt"
            else
                HOMEBREW_OPT="/usr/local/opt"
            fi
            ;;
        *)
            # Linux: Include Linuxbrew paths for uses_from_macos libs
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

    # Find Homebrew bison (MariaDB requires newer bison than system provides)
    local BISON_PATH="${HOMEBREW_OPT}/bison/bin/bison"
    if [ ! -f "$BISON_PATH" ]; then
        echo "Warning: Homebrew bison not found at $BISON_PATH, using system bison"
        BISON_PATH="$(command -v bison)"
    fi

    # Find Homebrew fmt location
    local FMT_DIR="${HOMEBREW_OPT}/fmt"

    cd "${SOURCE_DIR}"

    # Fix mysql_install_db.sh to use our prefix
    echo "→ Patching mysql_install_db.sh..."
    case "$OS_NAME" in
        Darwin)
            sed -i.bak "s|^basedir=.*|basedir=\"${PREFIX}\"|" scripts/mysql_install_db.sh
            sed -i.bak "s|^ldata=.*|ldata=\"${PREFIX}/data\"|" scripts/mysql_install_db.sh
            rm -f scripts/mysql_install_db.sh.bak
            ;;
        *)
            sed -i "s|^basedir=.*|basedir=\"${PREFIX}\"|" scripts/mysql_install_db.sh
            sed -i "s|^ldata=.*|ldata=\"${PREFIX}/data\"|" scripts/mysql_install_db.sh
            ;;
    esac

    # Remove bundled libraries (as per Homebrew formula)
    echo "→ Removing bundled libraries..."
    rm -rf storage/mroonga/vendor/groonga
    rm -rf extra/wolfssl
    rm -rf zlib
    echo "✓ Bundled libraries cleaned"

    # Determine library extension
    local LIB_EXT
    case "$OS_NAME" in
        Darwin) LIB_EXT="dylib" ;;
        *) LIB_EXT="so" ;;
    esac

    # CMake args (common)
    local CMAKE_ARGS=(
        -DCMAKE_INSTALL_PREFIX="${PREFIX}"
        -DCMAKE_PREFIX_PATH="${PREFIX}"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_FIND_FRAMEWORK=LAST
        -DCMAKE_VERBOSE_MAKEFILE=ON
        -DMYSQL_DATADIR="${PREFIX}/data"
        -DINSTALL_INCLUDEDIR=include/mysql
        -DINSTALL_MANDIR=share/man
        -DINSTALL_DOCDIR=share/doc/mariadb
        -DINSTALL_INFODIR=share/info
        -DINSTALL_MYSQLSHAREDIR=share/mysql
        -DINSTALL_SYSCONFDIR="${PREFIX}/etc"
        -DBISON_EXECUTABLE="${BISON_PATH}"
        -DLIBFMT_INCLUDE_DIR="${FMT_DIR}/include"
        -DPCRE2_INCLUDE_DIR="${PREFIX}/include"
        -DPCRE2_LIBRARY="${PREFIX}/lib/libpcre2-8.${LIB_EXT}"
        -DOPENSSL_ROOT_DIR="${PREFIX}"
        -DZLIB_INCLUDE_DIR="${PREFIX}/include"
        -DZLIB_LIBRARY="${PREFIX}/lib/libz.${LIB_EXT}"
        -DPLUGIN_PROVIDER_SNAPPY=NO
        -DWITH_ROCKSDB_Snappy=OFF
        -DWITH_LIBFMT=system
        -DWITH_PCRE=system
        -DWITH_SSL=system
        -DWITH_ZLIB=system
        -DWITH_UNIT_TESTS=OFF
        -DDEFAULT_CHARSET=utf8mb4
        -DDEFAULT_COLLATION=utf8mb4_general_ci
    )

    # Platform-specific CMake args
    case "$OS_NAME" in
        Darwin)
            # macOS: nothing extra needed
            ;;
        *)
            # Linux-specific args (from Homebrew formula)
            CMAKE_ARGS+=(
                -DWITH_NUMA=OFF
                -DENABLE_DTRACE=NO
                -DCONNECT_WITH_JDBC=OFF
                # RPATH so linker finds shared libs during build and at runtime
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
    cmake --build build -j"$NPROC"

    # Install directly to final location
    cmake --install build

    # Save space: remove test and benchmark directories (as per Homebrew formula)
    rm -rf "${PREFIX}/mariadb-test"
    rm -rf "${PREFIX}/sql-bench"

    # Install scripts symlinks (as per Homebrew formula)
    ln -sf "${PREFIX}/scripts/mariadb-install-db" "${PREFIX}/bin/mariadb-install-db"
    ln -sf "${PREFIX}/scripts/mysql_install_db" "${PREFIX}/bin/mysql_install_db"

    # Fix mysql.server script PATH
    if [ -f "${PREFIX}/support-files/mysql.server" ]; then
        case "$OS_NAME" in
            Darwin)
                sed -i.bak 's|^PATH="\(.*\)"|PATH="\1:'"${PREFIX}"'/bin"|' "${PREFIX}/support-files/mysql.server"
                rm -f "${PREFIX}/support-files/mysql.server.bak"
                sed -i.bak "s|^user='mysql'|user=\$(whoami)|" "${PREFIX}/support-files/mysql.server"
                rm -f "${PREFIX}/support-files/mysql.server.bak"
                ;;
            *)
                sed -i 's|^PATH="\(.*\)"|PATH="\1:'"${PREFIX}"'/bin"|' "${PREFIX}/support-files/mysql.server"
                sed -i "s|^user='mysql'|user=\$(whoami)|" "${PREFIX}/support-files/mysql.server"
                ;;
        esac

        # Install symlink
        ln -sf "${PREFIX}/support-files/mysql.server" "${PREFIX}/bin/mysql.server"
    fi

    # Move wsrep_sst_common to libexec (as per Homebrew formula)
    if [ -f "${PREFIX}/bin/wsrep_sst_common" ]; then
        mkdir -p "${PREFIX}/libexec"
        mv "${PREFIX}/bin/wsrep_sst_common" "${PREFIX}/libexec/"

        # Fix references in wsrep scripts
        for script in wsrep_sst_mysqldump wsrep_sst_rsync wsrep_sst_mariabackup; do
            if [ -f "${PREFIX}/bin/${script}" ]; then
                case "$OS_NAME" in
                    Darwin)
                        sed -i.bak "s|\$(dirname \"\$0\")/wsrep_sst_common|${PREFIX}/libexec/wsrep_sst_common|" "${PREFIX}/bin/${script}"
                        rm -f "${PREFIX}/bin/${script}.bak"
                        ;;
                    *)
                        sed -i "s|\$(dirname \"\$0\")/wsrep_sst_common|${PREFIX}/libexec/wsrep_sst_common|" "${PREFIX}/bin/${script}"
                        ;;
                esac
            fi
        done
    fi

    # Install my.cnf that binds to 127.0.0.1 by default (as per Homebrew formula)
    mkdir -p "${PREFIX}/etc"
    cat > "${PREFIX}/etc/my.cnf" <<'EOF'
# Default Homebrew MySQL server config
[mysqld]
# Only allow connections from localhost
bind-address = 127.0.0.1
EOF

    # Fix my.cnf to point to our PREFIX etc instead of /etc (as per Homebrew formula)
    mkdir -p "${PREFIX}/etc/my.cnf.d"
    touch "${PREFIX}/etc/my.cnf.d/.homebrew_dont_prune_me"

    echo "✓ ${PACKAGE_NAME} built successfully"
}
