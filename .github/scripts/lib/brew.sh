#!/usr/bin/env bash
# Homebrew formula API client and upstream formula resolution.
#
# BREW_API_BASE can point at any curl-reachable location, including a local
# directory via file://, which is how the test suite runs without network.

# These libraries use bash-only constructs such as ${!name} indirection.
[[ -n "${BASH_VERSION:-}" ]] || {
    echo "[brew] this library requires bash, not ${0##*/}" >&2
    return 1 2>/dev/null || exit 1
}

BREW_API_BASE="${BREW_API_BASE:-https://formulae.brew.sh/api/formula}"
BREW_SOURCE_BASE="${BREW_SOURCE_BASE:-https://raw.githubusercontent.com/Homebrew/homebrew-core/master}"

# shellcheck source=download.sh
source "$(dirname "${BASH_SOURCE[0]}")/download.sh"

brew_die() {
    echo "[brew] $1" >&2
    return 1
}

# Fetch one formula document. Prints JSON on stdout, fails if unknown.
# Usage: brew_formula_json <formula>
brew_formula_json() {
    local formula="$1"

    curl -fsSL --retry 3 --retry-delay 2 "${BREW_API_BASE}/${formula}.json" \
        || brew_die "formula not found upstream: $formula"
}

# Name of the Homebrew formula currently serving a line, where a line is a
# formula base plus an optional major pin, e.g. "mysql@9" or "openssl@3".
# Usage: brew_resolve_formula <line>
brew_resolve_formula() {
    local line="$1"

    local base="${line%@*}" pin=""
    [[ "$line" == *@* ]] && pin="${line#*@}"

    # Candidate names: the line itself, the base formula, and every versioned
    # sibling whose name already sits inside the pinned line.
    local -a candidates=("$line")
    [[ "$base" != "$line" ]] && candidates+=("$base")

    local base_json
    if base_json=$(brew_formula_json "$base" 2>/dev/null); then
        local sibling
        while read -r sibling; do
            [[ -n "$sibling" ]] && candidates+=("$sibling")
        done < <(jq -r --arg pin "$pin" \
            '.versioned_formulae[]? | select($pin == "" or startswith((split("@")[0]) + "@" + $pin + ".") or . == (split("@")[0] + "@" + $pin))' \
            <<<"$base_json")
    fi

    # Keep the candidates that actually exist and sit in the line, highest wins.
    local best="" best_version="" name version
    for name in "${candidates[@]}"; do
        version=$(brew_formula_json "$name" 2>/dev/null | jq -r '.versions.stable // empty') || continue
        [[ -n "$version" ]] || continue
        brew_version_in_line "$version" "$pin" || continue
        if [[ -z "$best" ]] || [[ "$(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -1)" == "$version" ]]; then
            best="$name"
            best_version="$version"
        fi
    done

    [[ -n "$best" ]] || { brew_die "no formula serves line: $line"; return 1; }
    printf '%s\n' "$best"
}

# True when a version belongs to a major line. An empty line matches anything.
# Usage: brew_version_in_line <version> <line>
brew_version_in_line() {
    local version="$1" pin="$2"

    [[ -z "$pin" ]] && return 0
    [[ "$version" == "$pin" || "$version" == "$pin".* ]]
}

# Normalised view of what a formula builds from: the stable tarball plus the
# checksums of the patches Homebrew applies on top of it.
# Usage: brew_source_of <formula>
brew_source_of() {
    local formula="$1" json

    json=$(brew_formula_json "$formula") || return 1

    # Only patches carrying a URL and a checksum can be replayed downstream.
    # The rest live inside the tap or inline in the formula, and are counted so
    # the divergence stays visible instead of silently accumulating.
    jq -c '
        ([.patches[]? | select(.url != null and .sha256 != null)]) as $replayable
        | {
            version: .versions.stable,
            url: .urls.stable.url,
            sha256: .urls.stable.checksum,
            source_path: .ruby_source_path,
            license: .license,
            patches: [$replayable[] | .sha256],
            unreplayable_patches: (((.patches // []) | length) - ($replayable | length))
        }' <<<"$json"
}

# Every formula related to the same package: the base one and its versioned
# siblings. Used to notice a major line upstream opened.
# Usage: brew_siblings <formula>
brew_siblings() {
    local formula="$1" json
    local base="${formula%@*}"

    json=$(brew_formula_json "$formula") || return 1
    {
        jq -r '.versioned_formulae[]?' <<<"$json"
        [[ "$base" != "$formula" ]] && brew_formula_json "$base" >/dev/null 2>&1 && printf '%s\n' "$base"
    } | sort -u
}

# Fingerprint of the build logic a formula describes: its file with the volatile
# parts stripped, so a version bump or a bottle rebuild leaves it untouched while
# a changed dependency, patch or install block moves it.
# Usage: brew_formula_fingerprint <ruby-source-path>
brew_formula_fingerprint() {
    local path="$1" source

    source=$(curl -fsSL --retry 3 --retry-delay 2 "${BREW_SOURCE_BASE}/${path}") \
        || brew_die "cannot read formula source: $path" || return 1

    # The nested `end` of a block inside livecheck is indented deeper, so the
    # two-space one always closes the block being skipped.
    awk '
        /^  (bottle|livecheck) do$/ { skip = 1; next }
        skip && /^  end$/           { skip = 0; next }
        skip                        { next }
        /^  (url|sha256|mirror|version|revision) / { next }
        { print }
    ' <<<"$source" | sha256_text
}
