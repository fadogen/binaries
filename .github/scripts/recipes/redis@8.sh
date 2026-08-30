#!/bin/bash
# Build recipe for redis@8
# Description: Persistent key-value database, with built-in net interface

set -e

# Metadata
export PACKAGE_NAME="redis@8"
export PACKAGE_VERSION="8.10.1"
export PACKAGE_SHA256="60166c95ab7aedaa9dfe516de685be0a4dd87be95ded59ba429df14c13f1b663"
export PACKAGE_LICENSE="AGPL-3.0-only AND Apache-2.0 AND BSD-2-Clause AND BSD-3-Clause AND BSL-1.0 AND MIT AND (CC0-1.0 OR BSD-2-Clause) AND (Artistic-1.0-Perl OR GPL-1.0-or-later)"

# Fingerprint of the Homebrew formula this recipe was transposed from.
# sync-upstream.sh reports when the formula's build logic moves past it.
export BREW_FORMULA_REVIEWED="79415aa261b0a2755036cb49910bd7765271ab91ffaad5e26c8544bc948ca7d4"

# Derived from version
export PACKAGE_URL="https://download.redis.io/releases/redis-${PACKAGE_VERSION}.tar.gz"

# Runtime dependencies
export DEPENDENCIES=(
    "openssl@3"
)

# Build tools for the bundled modules, installed via Homebrew and not shipped.
# RediSearch is C++/CMake, RedisJSON and vector-sets are Rust.
export BUILD_DEPENDENCIES=(
    "autoconf"
    "automake"
    "cmake"
    "coreutils"
    "libtool"
    "python@3.14"
    "rust"
)

# RediSearch needs GNU Make 4.0+, and macOS still ships 3.81 as `make`.
export BUILD_DEPENDENCIES_MACOS=(
    "make"
)

# Modules the `deploy` target is expected to produce. deploy.sh tolerates a
# module failing to build, so their presence is checked rather than assumed.
EXPECTED_MODULES=(
    "redisbloom.so"
    "redisearch.so"
    "redistimeseries.so"
    "rejson.so"
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

    # RediSearch sets CMAKE_CXX_STANDARD inside a function without PARENT_SCOPE,
    # so no -std reaches the compile line and the compiler default is used.
    export CXXFLAGS="${CXXFLAGS:-} -std=gnu++20"

    # Redis 8 ships its modules in the tarball and builds them through GNU Make
    # 4.0+. macOS still provides 3.81 as `make`, so use the `gmake` Homebrew
    # installs; Linux already ships GNU Make 4.
    local MAKE_BIN="make"
    if [ "$(uname)" = "Darwin" ]; then
        MAKE_BIN="gmake"
    fi

    # `deploy` builds and installs the server together with the bundled modules
    # (RediSearch, RedisJSON, RedisBloom, RedisTimeSeries). `install` alone
    # leaves them out, which is what this recipe used to ship.
    # BUILD_TLS=yes enables TLS support with OpenSSL.
    # LD=cc is required on macOS: redis' tests/modules/Makefile links .so via
    # $(LD), which falls back to bare `ld` on Darwin and can't parse the
    # `-Wl,-headerpad_max_install_names` syntax in LDFLAGS. On Linux the
    # modules Makefile forces LD=gcc internally so this is a no-op there.
    MAKE="${MAKE_BIN}" "$MAKE_BIN" -j"${NPROC}" deploy \
        PREFIX="${PREFIX}" \
        CC="${CC:-cc}" \
        LD="${CC:-cc}" \
        BUILD_TLS=yes \
        REDISEARCH_GENERATE_HEADERS=0 \
        IGNORE_MISSING_DEPS=1 \
        LTO=0

    # deploy.sh returns success when only some modules built, so a silent
    # partial bundle is possible. Refuse it.
    local missing=""
    for module in "${EXPECTED_MODULES[@]}"; do
        [ -f "${PREFIX}/lib/redis/modules/${module}" ] || missing="${missing} ${module}"
    done
    if [ -n "$missing" ]; then
        echo "✗ modules missing from the build:${missing}" >&2
        return 1
    fi

    echo "✓ ${PACKAGE_NAME} built successfully"
}

post_install() {
    local PREFIX="$1"

    # Redis dlopens its modules and refuses any file without the execute bit.
    chmod 0755 "${PREFIX}"/lib/redis/modules/*.so
}
