#!/usr/bin/env bash
# Repackage the existing vendor distributions into Fadogen's Windows layout.
set -euo pipefail

service="${1:-}"
version="${2:-}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    echo 'Usage: services-windows-downloader.sh <service> <numeric-version>' >&2
    exit 1
fi

case "$service" in
    mysql)
        source_root="mysql-${version}-winx64"
        url="https://cdn.mysql.com/Downloads/MySQL-${version%.*}/${source_root}.zip"
        ;;
    mariadb)
        source_root="mariadb-${version}-winx64"
        url="https://archive.mariadb.org/mariadb-${version}/winx64-packages/${source_root}.zip"
        ;;
    postgresql)
        source_root=pgsql
        url="https://get.enterprisedb.com/postgresql/postgresql-${version}-1-windows-x64-binaries.zip"
        ;;
    redis)
        source_root="redis-windows-${version}"
        url="https://github.com/zkteco-home/redis-windows/archive/refs/tags/${version}.zip"
        ;;
    *)
        echo "No Windows distribution configured for: $service" >&2
        exit 1
        ;;
esac

output="$PWD/${service}-${version}-windows-x86_64.zip"
workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
curl -fSL --retry 3 --retry-delay 5 -o "$workspace/source.zip" "$url"
unzip -q "$workspace/source.zip" -d "$workspace/extracted"
mv "$workspace/extracted/$source_root" "$workspace/${service}-${version}"
(cd "$workspace" && zip -rq "$output" "${service}-${version}")
echo "$output"
