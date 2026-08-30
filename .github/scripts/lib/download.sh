#!/bin/bash
# Download and verify package archives

# Hash a local file with whatever sha256 tool the platform provides.
# Usage: sha256_file <path>
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Hash the artefact served at a URL without keeping it on disk.
# Usage: sha256_of_url <url>
sha256_of_url() {
    local url="$1" tmp sum
    tmp="$(mktemp)"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
        rm -f "$tmp"
        echo "[download] cannot fetch $url" >&2
        return 1
    fi
    sum="$(sha256_file "$tmp")"
    rm -f "$tmp"
    printf '%s\n' "$sum"
}

# Download and verify package
# Usage: download_package <url> <sha256>
# Returns: filepath (stdout)
download_package() {
    local url="$1"
    local sha256="$2"

    local filename
    filename=$(basename "$url")
    local filepath="${DOWNLOADS_DIR}/${filename}"

    mkdir -p "${DOWNLOADS_DIR}"

    # Download if not cached
    if [ ! -f "$filepath" ]; then
        echo -e "${BLUE}→ Downloading ${filename}...${NC}" >&2
        curl -L -o "$filepath" "$url" >/dev/null 2>&1
    else
        echo -e "${YELLOW}↺ Using cached ${filename}${NC}" >&2
    fi

    # Verify checksum
    echo -e "${BLUE}→ Verifying checksum...${NC}" >&2
    local actual_sha256
    actual_sha256=$(sha256_file "$filepath")
    if [ "$actual_sha256" != "$sha256" ]; then
        echo -e "${RED}✗ Checksum mismatch!${NC}" >&2
        echo -e "  Expected: $sha256" >&2
        echo -e "  Actual:   $actual_sha256" >&2
        return 1
    fi
    echo -e "${GREEN}✓ Checksum verified${NC}" >&2

    # Return ONLY the filepath (to stdout)
    echo "$filepath"
}
