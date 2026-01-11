#!/usr/bin/env bash
# One-shot script to fix corrupted metadata keys
# The issue: grep without -h prefixed filename to each line, corrupting service names
#
# Before: "checksum-mariadb-10.11.15-arm64.txt:mariadb": { "10": {...} }
# After:  "mariadb": { "10": {...} }
#
# Usage: ./fix-metadata-keys.sh
# Requires: AWS credentials configured for R2 access

set -euo pipefail

R2_BUCKET="${R2_BUCKET_NAME:-fadogen}"
R2_ENDPOINT="${R2_ENDPOINT:-https://24a64820e8b32bc33574fa8f17d35268.r2.cloudflarestorage.com}"

fix_metadata() {
    local arch="$1"
    local metadata_file="metadata-services-${arch}.json"

    echo "Processing $metadata_file..."

    # Download current metadata
    if ! aws s3 cp "s3://${R2_BUCKET}/${metadata_file}" "${metadata_file}" --endpoint-url "${R2_ENDPOINT}" 2>/dev/null; then
        echo "  [SKIP] File not found on R2"
        return 0
    fi

    # Check if already fixed (first key should be a simple service name)
    local first_key
    first_key=$(jq -r 'keys[0]' "$metadata_file")
    if [[ ! "$first_key" == *":"* ]]; then
        echo "  [OK] Already fixed (first key: $first_key)"
        rm -f "$metadata_file"
        return 0
    fi

    echo "  [FIX] Corrupted keys detected, fixing..."

    # Transform: extract service name from corrupted key, merge values
    jq '
      reduce to_entries[] as $entry ({};
        # Extract real service name (after the ":")
        ($entry.key | split(":")[1]) as $service |
        # Merge the major version data under the correct service key
        .[$service] = (.[$service] // {}) + $entry.value
      )
    ' "$metadata_file" > "${metadata_file}.fixed"

    # Show diff
    echo "  Before:"
    jq -r 'keys | join(", ")' "$metadata_file" | head -c 100
    echo "..."
    echo "  After:"
    jq -r 'keys | join(", ")' "${metadata_file}.fixed"

    # Upload fixed metadata
    aws s3 cp "${metadata_file}.fixed" "s3://${R2_BUCKET}/${metadata_file}" --endpoint-url "${R2_ENDPOINT}" >/dev/null
    echo "  [DONE] Uploaded fixed $metadata_file"

    # Cleanup
    rm -f "$metadata_file" "${metadata_file}.fixed"
}

echo "=== Fixing corrupted metadata keys ==="
echo ""

for arch in arm64 x86_64; do
    fix_metadata "$arch"
    echo ""
done

echo "=== Done ==="
