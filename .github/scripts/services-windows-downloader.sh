#!/usr/bin/env bash
set -euo pipefail

# ================================
# SERVICES WINDOWS DOWNLOADER
# ================================
# Downloads and repackages pre-built Windows binaries for database services
# Usage: services-windows-downloader.sh <service> <version>
#
# Supported services: mysql, mariadb, postgresql, redis
# Note: Valkey is NOT supported on Windows (no port exists)
# Redis Windows is provided by zkteco-home/redis-windows (community port)

# ================================
# UTILITY FUNCTIONS
# ================================

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Extract major.minor from version (e.g., "8.4.3" -> "8.4")
get_major_minor() {
    local version="$1"
    echo "${version%.*}"
}

# Extract major from version (e.g., "8.4.3" -> "8")
get_major() {
    local version="$1"
    echo "${version%%.*}"
}

# ================================
# DOWNLOAD FUNCTIONS
# ================================

download_mysql() {
    local version="$1"
    local major_minor
    major_minor=$(get_major_minor "$version")

    local url="https://cdn.mysql.com/Downloads/MySQL-${major_minor}/mysql-${version}-winx64.zip"
    local temp_zip="mysql-${version}-winx64.zip"
    local extract_dir="mysql-${version}-winx64"
    local output_dir="mysql-${version}"
    local output_archive="mysql-${version}-windows-x86_64.zip"

    log_info "Downloading MySQL ${version} from ${url}"
    curl -fSL --retry 3 --retry-delay 5 -o "$temp_zip" "$url"

    log_info "Extracting archive..."
    unzip -q "$temp_zip"

    log_info "Repackaging to consistent format..."
    mv "$extract_dir" "$output_dir"

    # Create final archive
    zip -rq "$output_archive" "$output_dir"

    # Cleanup
    rm -rf "$temp_zip" "$output_dir"

    log_info "Created $output_archive"
    echo "$output_archive"
}

download_mariadb() {
    local version="$1"

    local url="https://archive.mariadb.org/mariadb-${version}/winx64-packages/mariadb-${version}-winx64.zip"
    local temp_zip="mariadb-${version}-winx64.zip"
    local extract_dir="mariadb-${version}-winx64"
    local output_dir="mariadb-${version}"
    local output_archive="mariadb-${version}-windows-x86_64.zip"

    log_info "Downloading MariaDB ${version} from ${url}"
    curl -fSL --retry 3 --retry-delay 5 -o "$temp_zip" "$url"

    log_info "Extracting archive..."
    unzip -q "$temp_zip"

    log_info "Repackaging to consistent format..."
    mv "$extract_dir" "$output_dir"

    # Create final archive
    zip -rq "$output_archive" "$output_dir"

    # Cleanup
    rm -rf "$temp_zip" "$output_dir"

    log_info "Created $output_archive"
    echo "$output_archive"
}

download_postgresql() {
    local version="$1"

    local url="https://get.enterprisedb.com/postgresql/postgresql-${version}-1-windows-x64-binaries.zip"
    local temp_zip="postgresql-${version}-windows-x64-binaries.zip"
    local extract_dir="pgsql"
    local output_dir="postgresql-${version}"
    local output_archive="postgresql-${version}-windows-x86_64.zip"

    log_info "Downloading PostgreSQL ${version} from ${url}"
    curl -fSL --retry 3 --retry-delay 5 -o "$temp_zip" "$url"

    log_info "Extracting archive..."
    unzip -q "$temp_zip"

    log_info "Repackaging to consistent format..."
    mv "$extract_dir" "$output_dir"

    # Create final archive
    zip -rq "$output_archive" "$output_dir"

    # Cleanup
    rm -rf "$temp_zip" "$output_dir"

    log_info "Created $output_archive"
    echo "$output_archive"
}

download_redis() {
    local version="$1"

    # zkteco-home/redis-windows provides Windows builds of Redis
    local url="https://github.com/zkteco-home/redis-windows/archive/refs/tags/${version}.zip"
    local temp_zip="redis-windows-${version}.zip"
    local extract_dir="redis-windows-${version}"
    local output_dir="redis-${version}"
    local output_archive="redis-${version}-windows-x86_64.zip"

    log_info "Downloading Redis ${version} from ${url}"
    curl -fSL --retry 3 --retry-delay 5 -o "$temp_zip" "$url"

    log_info "Extracting archive..."
    unzip -q "$temp_zip"

    log_info "Repackaging to consistent format..."
    mv "$extract_dir" "$output_dir"

    # Create final archive
    zip -rq "$output_archive" "$output_dir"

    # Cleanup
    rm -rf "$temp_zip" "$output_dir"

    log_info "Created $output_archive"
    echo "$output_archive"
}

# ================================
# MAIN
# ================================

main() {
    local service="${1:-}"
    local version="${2:-}"

    if [[ -z "$service" || -z "$version" ]]; then
        log_error "Usage: $0 <service> <version>"
    fi

    case "$service" in
        mysql)
            download_mysql "$version"
            ;;
        mariadb)
            download_mariadb "$version"
            ;;
        postgresql)
            download_postgresql "$version"
            ;;
        redis)
            download_redis "$version"
            ;;
        valkey)
            log_error "$service is not supported on Windows (no port exists)"
            ;;
        *)
            log_error "Unknown service: $service"
            ;;
    esac
}

main "$@"
