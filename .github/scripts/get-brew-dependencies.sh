#!/usr/bin/env bash
set -euo pipefail

# List the recursive runtime and build dependencies of a Homebrew formula, in
# topological order: dependencies before the packages that need them, which is
# the order recipes have to be written in.
#
# Usage: ./get-brew-dependencies.sh <formula>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/colors.sh
source "${SCRIPT_DIR}/lib/colors.sh"
# shellcheck source=lib/brew.sh
source "${SCRIPT_DIR}/lib/brew.sh"

declare -A VISITED=()
declare -a DEP_ORDER=()

walk_dependencies() {
    local package="$1" indent="$2"
    local formula json dep

    if ! formula="$(brew_resolve_formula "$package")"; then
        echo -e "${indent}${RED}✗ Cannot find a formula for '$package'${NC}" >&2
        return 1
    fi

    if [[ -n "${VISITED[$formula]:-}" ]]; then
        echo -e "${indent}${YELLOW}↺ $formula (already processed)${NC}" >&2
        return 0
    fi
    VISITED[$formula]=1

    echo -e "${indent}${BLUE}→ $formula${NC}" >&2
    json="$(brew_formula_json "$formula")"

    # Runtime dependencies first, then build ones, matching the order a bundle
    # gets assembled in.
    while read -r dep; do
        [[ -n "$dep" ]] || continue
        walk_dependencies "$dep" "${indent}  "
    done < <(jq -r '(.dependencies // [])[], (.build_dependencies // [])[]' <<<"$json")

    DEP_ORDER+=("$formula")
}

main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <formula>"
        echo "Example: $0 postgresql@18"
        exit 1
    fi

    echo -e "${GREEN}=== Fetching dependencies for $1 ===${NC}" >&2
    walk_dependencies "$1" ""
    echo -e "${GREEN}=== Dependency order (build from top to bottom) ===${NC}" >&2

    printf '%s\n' "${DEP_ORDER[@]}"
}

main "$@"
