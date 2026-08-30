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
