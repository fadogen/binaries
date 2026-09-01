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

# Hash whatever arrives on stdin.
sha256_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
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
# Usage: download_package <url> <sha256> [mirror-url...]
# Returns: filepath (stdout)
#
# Mirrors matter as much as retries here: upstream hosts go down for minutes at
# a time, and retrying the one that is down does not help. kerberos.org broke
# two consecutive runs on its own.
download_package() {
    local url="$1"
    local sha256="$2"
    shift 2
    local mirrors=("$@")

    local filename
    filename=$(basename "$url")
    local filepath="${DOWNLOADS_DIR}/${filename}"

    mkdir -p "${DOWNLOADS_DIR}"

    # Download if not cached
    if [ ! -f "$filepath" ]; then
        local source fetched=false
        for source in "$url" "${mirrors[@]}"; do
            echo -e "${BLUE}→ Downloading ${filename}...${NC}" >&2

            # -f so an HTTP error is an error rather than a saved error page, and
            # the exit code is checked: without this a failed download reached the
            # checksum step and was reported as a corrupted source, blaming the
            # archive for the host being down.
            if curl -fL --retry 3 --retry-delay "${DOWNLOAD_RETRY_DELAY:-5}" --retry-all-errors \
                -o "$filepath" "$source" 2>/dev/null; then
                fetched=true
                break
            fi

            rm -f "$filepath"
            echo -e "${YELLOW}↺ unreachable: ${source}${NC}" >&2
        done

        if [ "$fetched" != "true" ]; then
            echo -e "${RED}✗ download failed: ${url}${NC}" >&2
            return 1
        fi
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
