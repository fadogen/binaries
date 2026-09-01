#!/usr/bin/env bash
# Read and write the metadata block of a build recipe.
#
# Writes are surgical on purpose: only the declaration being replaced changes,
# so a synced recipe stays reviewable as a one-line diff.

# These libraries use bash-only constructs such as ${!name} indirection.
[[ -n "${BASH_VERSION:-}" ]] || {
    echo "[recipe] this library requires bash, not ${0##*/}" >&2
    return 1 2>/dev/null || exit 1
}

# shellcheck source=download.sh
source "$(dirname "${BASH_SOURCE[0]}")/download.sh"

recipe_die() {
    echo "[recipe] $1" >&2
    return 1
}

# Overwrite a recipe in place, preserving its inode and mode.
_recipe_write() {
    local file="$1"
    shift
    printf '%s\n' "$@" > "$file"
}

# Strip the leading "export " / "declare -a " keywords of a declaration line.
_recipe_declaration_prefix() {
    local line="$1" keyword
    for keyword in "export " "declare -ax " "declare -a " "declare "; do
        [[ "$line" == "$keyword"* ]] && { printf '%s' "$keyword"; return 0; }
    done
    printf ''
}

# Read one metadata field from a recipe, with its templates expanded.
# Usage: recipe_field <recipe-file> <FIELD>
recipe_field() {
    local file="$1" field="$2"

    [[ -f "$file" ]] || recipe_die "recipe not found: $file" || return 1

    # shellcheck source=/dev/null  # the recipe path is the argument
    ( set +e; source "$file" >/dev/null 2>&1; printf '%s\n' "${!field}" )
}

# Replace the literal value of one scalar field.
# Usage: recipe_set_field <recipe-file> <FIELD> <value>
recipe_set_field() {
    local file="$1" field="$2" value="$3"

    [[ -f "$file" ]] || recipe_die "recipe not found: $file" || return 1

    local -a out=()
    local line prefix hits=0
    while IFS= read -r line; do
        prefix="$(_recipe_declaration_prefix "$line")"
        if [[ "${line#"$prefix"}" == "${field}="* ]]; then
            out+=("${prefix}${field}=\"${value}\"")
            hits=$((hits + 1))
        else
            out+=("$line")
        fi
    done < "$file"

    (( hits > 0 )) || recipe_die "no such field in $(basename "$file"): $field" || return 1
    _recipe_write "$file" "${out[@]}"
}

# Whether a recipe declares a given array at all.
# Usage: recipe_declares_array <recipe-file> <NAME>
recipe_declares_array() {
    local file="$1" name="$2" line prefix

    [[ -f "$file" ]] || return 1

    while IFS= read -r line; do
        prefix="$(_recipe_declaration_prefix "$line")"
        [[ "${line#"$prefix"}" == "${name}=("* ]] && return 0
    done < "$file"

    return 1
}

# Replace a bash array declaration, however many entries it had before.
# Usage: recipe_set_array <recipe-file> <NAME> [value...]
recipe_set_array() {
    local file="$1" name="$2"
    shift 2

    [[ -f "$file" ]] || recipe_die "recipe not found: $file" || return 1

    local -a out=()
    local line prefix hits=0 inside=0 value
    while IFS= read -r line; do
        if (( inside )); then
            [[ "$line" == ")"* ]] && inside=0
            continue
        fi

        prefix="$(_recipe_declaration_prefix "$line")"
        if [[ "${line#"$prefix"}" == "${name}=("* ]]; then
            out+=("${prefix}${name}=(")
            for value in "$@"; do
                out+=("    \"${value}\"")
            done
            out+=(")")
            hits=$((hits + 1))
            # A one-line declaration closes immediately; a multi-line one does not.
            [[ "$line" == *")" ]] || inside=1
            continue
        fi

        out+=("$line")
    done < "$file"

    (( hits > 0 )) || recipe_die "no such array in $(basename "$file"): $name" || return 1
    _recipe_write "$file" "${out[@]}"
}

# Names of every recipe a package pulls in at runtime, itself included, in
# depth-first order. Platform-specific lists are merged, so the fingerprint of a
# service covers what its bundle actually embeds on this OS.
# The OS is an argument, not the machine's: metadata for every platform is
# written from a single Linux runner.
# Usage: recipe_dependency_closure <recipe-name> [os]
recipe_dependency_closure() {
    local name="$1" os="${2:-}"
    [[ -n "$os" ]] || { [[ "$(uname)" == "Darwin" ]] && os="darwin" || os="linux"; }
    local -A seen=()
    local -a stack=("$name") order=()

    while (( ${#stack[@]} > 0 )); do
        local current="${stack[0]}"
        stack=("${stack[@]:1}")
        [[ -n "${seen[$current]:-}" ]] && continue
        seen[$current]=1
        order+=("$current")

        local file="${RECIPES_DIR}/${current}.sh"
        [[ -f "$file" ]] || continue

        local dep
        while read -r dep; do
            [[ -n "$dep" ]] && stack+=("$dep")
        done < <(
            set +e
            # shellcheck source=/dev/null
            source "$file" >/dev/null 2>&1
            if [[ "$os" == "darwin" ]]; then
                printf '%s\n' "${DEPENDENCIES[@]}" "${DEPENDENCIES_MACOS[@]}" 2>/dev/null
            else
                printf '%s\n' "${DEPENDENCIES[@]}" "${DEPENDENCIES_LINUX[@]}" 2>/dev/null
            fi
        )
    done

    printf '%s\n' "${order[@]}"
}

# Fields that say how to obtain the source or track the recipe, never what the
# build produces. PACKAGE_SHA256 already identifies the source; a URL is only a
# route to it, and a review marker or a licence changes no byte of the binary.
RECIPE_DIGEST_IGNORED=(
    PACKAGE_URL
    PACKAGE_MIRRORS
    PACKAGE_LICENSE
    BREW_FORMULA_REVIEWED
)

# What a recipe contributes to a bundle: its source, its patches, its
# dependencies and the code that compiles them.
#
# Both halves are printed back by bash itself, not read from the file, so the
# digest describes what the recipe means rather than how it is written.
# `declare -p` prints variables in canonical form and `declare -f` reprints
# functions without comments and with normalised indentation. Reformatting a
# recipe, or documenting it, therefore rebuilds nothing.
# Usage: recipe_build_digest <recipe-file>
recipe_build_digest() {
    local file="$1"

    [[ -f "$file" ]] || { printf 'missing\n'; return 0; }

    (
        set +e
        __digest_before=$(compgen -v | sort)
        # shellcheck source=/dev/null
        source "$file" >/dev/null 2>&1

        # Every variable the recipe defined, minus the ones that describe
        # nothing about the output. Names starting with __ are this function's.
        local __digest_name
        while read -r __digest_name; do
            [[ " ${RECIPE_DIGEST_IGNORED[*]} " == *" ${__digest_name} "* ]] && continue
            declare -p "$__digest_name" 2>/dev/null
        done < <(comm -13 <(printf '%s\n' "$__digest_before") <(compgen -v | sort) | grep -v '^__digest_')

        # upstream_extra serves the sync, not the build, so it is left out.
        #
        # The trailing-semicolon strip matters: bash 5.2 and 5.3 disagree on
        # whether the last command of a block gets one when reprinting a
        # function. Without it the digest depends on the bash that computed it,
        # and a runner image upgrade would rebuild everything.
        declare -f build post_install 2>/dev/null | sed 's/;[[:space:]]*$//'
    ) | sha256_text
}

# Fingerprint of what a bundle will contain: every recipe in its closure, with
# the build each one describes. It moves when a dependency is bumped and when
# the code building it changes, both of which a comparison on the service's own
# version would miss.
# Usage: recipe_dependency_fingerprint <recipe-name> [os]
recipe_dependency_fingerprint() {
    local name="$1" os="${2:-}" dep

    while read -r dep; do
        [[ -n "$dep" ]] || continue
        printf '%s=%s\n' "$dep" "$(recipe_build_digest "${RECIPES_DIR}/${dep}.sh")"
    done < <(recipe_dependency_closure "$name" "$os") | sort | sha256_text
}
