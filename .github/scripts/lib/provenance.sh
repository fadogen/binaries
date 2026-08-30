#!/usr/bin/env bash
# Build the provenance notice that ships inside every bundle.
#
# The bundles carry copyleft components, Redis and MariaDB among them, whose
# licences require the recipient to be told where the corresponding source is.
# Nothing here is compiled from modified sources, so pointing at the exact
# upstream archive and its checksum satisfies that.

[[ -n "${BASH_VERSION:-}" ]] || {
    echo "[provenance] this library requires bash, not ${0##*/}" >&2
    return 1 2>/dev/null || exit 1
}

PROVENANCE_REPOSITORY="${PROVENANCE_REPOSITORY:-https://github.com/fadogen/binaries}"

# Usage: provenance_document <title> <recipe-file>...
provenance_document() {
    local title="$1"
    shift

    cat <<HEADER
Source provenance for ${title}

Every component below was compiled from an unmodified upstream release. Each is
listed with the exact archive it was built from and that archive's SHA-256
checksum, so the corresponding source can be fetched and verified independently.

The build recipes are public: ${PROVENANCE_REPOSITORY}

HEADER

    local file name version license url sha256
    for file in "$@"; do
        name="$(recipe_field "$file" PACKAGE_NAME)" || return 1
        version="$(recipe_field "$file" PACKAGE_VERSION)" || return 1
        license="$(recipe_field "$file" PACKAGE_LICENSE)" || return 1
        url="$(recipe_field "$file" PACKAGE_URL)" || return 1
        sha256="$(recipe_field "$file" PACKAGE_SHA256)" || return 1

        [[ -n "$name" && -n "$version" && -n "$url" && -n "$sha256" ]] || {
            echo "[provenance] incomplete metadata in $(basename "$file")" >&2
            return 1
        }

        printf '%s %s\n' "$name" "$version"
        printf '  license  %s\n' "${license:-unknown}"
        printf '  source   %s\n' "$url"
        printf '  sha256   %s\n\n' "$sha256"
    done
}

# Write the notice into a bundle. Built in memory first: a truncated
# PROVENANCE.txt would be a claim the bundle cannot back.
# Usage: provenance_write <bundle-dir> <title> <recipe-file>...
provenance_write() {
    local bundle="$1" title="$2"
    shift 2

    local document
    document="$(provenance_document "$title" "$@")" || return 1

    printf '%s' "$document" > "${bundle}/PROVENANCE.txt"
}
