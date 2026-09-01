#!/usr/bin/env bash
set -euo pipefail

# ================================
# UPSTREAM VERSION SYNC
# ================================
# Keeps every build recipe aligned with the Homebrew formula it tracks.
#
#   sync-upstream.sh check           Report drift, write nothing.
#   sync-upstream.sh apply           Report drift and rewrite the outdated recipes.
#   sync-upstream.sh review <recipe> Mark the formula's build logic as reviewed.
#   sync-upstream.sh summary         Markdown digest of a report read on stdin.
#   sync-upstream.sh attention       What needs a human decision, empty if nothing does.
#   sync-upstream.sh commit-message  Commit message for a report read on stdin.
#   sync-upstream.sh commit          Commit the synced recipes, if any changed.
#
# The report goes to stdout as JSON; progress goes to stderr.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPES_DIR="${RECIPES_DIR:-${SCRIPT_DIR}/recipes}"

# shellcheck source=lib/brew.sh
source "${SCRIPT_DIR}/lib/brew.sh"
# shellcheck source=lib/recipe.sh
source "${SCRIPT_DIR}/lib/recipe.sh"
# shellcheck source=lib/download.sh
source "${SCRIPT_DIR}/lib/download.sh"

log() { echo "[sync] $1" >&2; }

# Fields a recipe derives for itself, printed as FIELD=value by its optional
# upstream_extra hook. Silent for the recipes that do not define one.
recipe_extra_fields() {
    local file="$1" version="$2"

    (
        set +e
        # shellcheck source=/dev/null
        source "$file" >/dev/null 2>&1
        declare -F upstream_extra >/dev/null 2>&1 || exit 0
        upstream_extra "$version"
    )
}

# The major line a formula or recipe name sits on, e.g. postgresql@18 -> 18,
# mysql@9.7 -> 9. Falls back to the version when the name carries no pin.
line_major() {
    local name="$1" version="${2:-}" pin
    if [[ "$name" == *@* ]]; then
        pin="${name#*@}"
    else
        pin="$version"
    fi
    printf '%s' "${pin%%.*}"
}

# Rewrite a recipe to match what upstream ships. Any failure aborts before the
# real file is touched: a half-synced recipe would poison every build using it.
apply_recipe() {
    local file="$1" source_json="$2"
    local staged

    staged="$(mktemp)"
    cp "$file" "$staged"

    if _sync_into "$staged" "$source_json"; then
        cat "$staged" > "$file"
        rm -f "$staged"
        echo "updated"
    else
        rm -f "$staged"
        log "leaving $(basename "$file" .sh) untouched, sync failed"
        echo "failed"
    fi
}

_sync_into() {
    local file="$1" source_json="$2"
    local recipe_url upstream_url sha256 version assignment

    version="$(jq -r '.version' <<<"$source_json")"
    recipe_set_field "$file" PACKAGE_VERSION "$version" || return 1

    # A recipe whose URL needs more than the version resolves the rest itself.
    # Captured first: a process substitution would swallow the hook's failure.
    local extra
    extra="$(recipe_extra_fields "$file" "$version")" || return 1
    while IFS= read -r assignment; do
        [[ "$assignment" == *=* ]] || continue
        log "recipe resolved ${assignment%%=*}"
        recipe_set_field "$file" "${assignment%%=*}" "${assignment#*=}" || return 1
    done <<<"$extra"

    # A recipe is free to build its own source URL, for instance to pick a
    # bundled tarball Homebrew does not use. The formula checksum then describes
    # a different artefact, so hash the one the recipe actually downloads.
    recipe_url="$(recipe_field "$file" PACKAGE_URL)"
    upstream_url="$(jq -r '.url' <<<"$source_json")"
    if [[ "$recipe_url" == "$upstream_url" ]]; then
        sha256="$(jq -r '.sha256' <<<"$source_json")"
    else
        log "custom source URL, hashing $recipe_url"
        sha256="$(sha256_of_url "$recipe_url")" || return 1
    fi
    [[ -n "$sha256" && "$sha256" != "null" ]] || return 1
    recipe_set_field "$file" PACKAGE_SHA256 "$sha256" || return 1

    # Recipes that replay upstream patches carry their checksums too. A recipe
    # that does not declare the array simply builds the plain tarball, which the
    # report states rather than treating as a failure.
    local -a patches=()
    local patch
    while IFS= read -r patch; do
        [[ -n "$patch" ]] && patches+=("$patch")
    done < <(jq -r '.patches[]' <<<"$source_json")
    if (( ${#patches[@]} > 0 )) && recipe_declares_array "$file" PATCH_CHECKSUMS; then
        recipe_set_array "$file" PATCH_CHECKSUMS "${patches[@]}" || return 1
    fi
}

# Keep the recipe's licence expression in step with the formula, for recipes
# that declare the field. Silent for those that do not.
sync_license() {
    local file="$1" source_json="$2" upstream

    upstream="$(jq -r '.license // empty' <<<"$source_json")"
    [[ -n "$upstream" ]] || return 0
    [[ "$(recipe_field "$file" PACKAGE_LICENSE)" == "$upstream" ]] && return 0

    recipe_set_field "$file" PACKAGE_LICENSE "$upstream" 2>/dev/null || return 0
    log "$(basename "$file" .sh): licence recorded as ${upstream}"
}

# One report entry per recipe, as compact JSON.
inspect_recipe() {
    local file="$1" command="$2"
    local recipe formula local_version source_json status

    recipe="$(basename "$file" .sh)"
    local_version="$(recipe_field "$file" PACKAGE_VERSION)"

    # An unknown line is reported, never guessed at, and never fatal: the other
    # recipes still deserve their update.
    if ! formula="$(brew_resolve_formula "$recipe")" || ! source_json="$(brew_source_of "$formula")"; then
        jq -cn --arg recipe "$recipe" --arg from "$local_version" \
            '{recipe: $recipe, formula: null, from: $from, to: null, status: "unresolved"}'
        return 0
    fi

    # The licence is derived metadata, not a build input: it is kept in step
    # whatever the version does, and never triggers a rebuild on its own.
    sync_license "$file" "$source_json"

    if [[ "$local_version" == "$(jq -r '.version' <<<"$source_json")" ]]; then
        status="current"
    elif [[ "$command" == "apply" ]]; then
        log "updating ${recipe}: ${local_version} -> $(jq -r '.version' <<<"$source_json")"
        status="$(apply_recipe "$file" "$source_json")"
    else
        status="outdated"
    fi

    # A recipe transposes the formula's build logic by hand. When that logic
    # moves, the version sync alone is no longer enough and a human has to look.
    local reviewed current_fingerprint formula_changed=false
    reviewed="$(recipe_field "$file" BREW_FORMULA_REVIEWED)"
    if [[ -n "$reviewed" ]]; then
        current_fingerprint="$(brew_formula_fingerprint "$(jq -r '.source_path' <<<"$source_json")" 2>/dev/null)" || current_fingerprint=""
        [[ -n "$current_fingerprint" && "$current_fingerprint" != "$reviewed" ]] && formula_changed=true
    fi

    # Patches upstream applies that this recipe does not: either they cannot be
    # fetched, or the recipe declares no checksum array to replay them into.
    local not_replayed
    not_replayed="$(jq -r '.unreplayable_patches' <<<"$source_json")"
    if ! recipe_declares_array "$file" PATCH_CHECKSUMS; then
        not_replayed=$(( not_replayed + $(jq -r '.patches | length' <<<"$source_json") ))
    fi

    jq -cn \
        --arg recipe "$recipe" \
        --arg formula "$formula" \
        --arg from "$local_version" \
        --arg status "$status" \
        --argjson not_replayed "$not_replayed" \
        --argjson formula_changed "$formula_changed" \
        --argjson upstream "$source_json" \
        '{
            recipe: $recipe,
            formula: $formula,
            from: $from,
            to: $upstream.version,
            status: $status,
            patches_not_replayed: $not_replayed,
            formula_changed: $formula_changed,
            formula_path: $upstream.source_path
        }'
}

# Formulae upstream serves on a major line above the one a recipe tracks.
# Prints "<package> <major> <formula>" so the caller can drop the lines that
# another recipe already covers.
new_lines_for() {
    local recipe="$1" formula="$2" version="$3"
    local package mine sibling theirs

    package="${recipe%@*}"
    mine="$(line_major "$recipe" "$version")"
    [[ "$mine" =~ ^[0-9]+$ ]] || return 0

    while read -r sibling; do
        [[ -n "$sibling" ]] || continue
        if [[ "$sibling" == *@* ]]; then
            theirs="$(line_major "$sibling")"
        else
            theirs="$(line_major "$sibling" "$(brew_source_of "$sibling" 2>/dev/null | jq -r '.version // empty')")"
        fi
        [[ "$theirs" =~ ^[0-9]+$ ]] || continue
        (( theirs > mine )) && printf '%s %s %s\n' "$package" "$theirs" "$sibling"
    done < <(brew_siblings "$formula" 2>/dev/null)
    return 0
}

# Record that a human has read the formula as it stands today and carried over
# whatever mattered. Until then the sync keeps asking.
# Usage: review <recipe>
review_recipe() {
    local recipe="${1:-}" file formula fingerprint

    [[ -n "$recipe" ]] || { echo "usage: $(basename "$0") review <recipe>" >&2; return 2; }

    file="${RECIPES_DIR}/${recipe}.sh"
    [[ -f "$file" ]] || { echo "[sync] no such recipe: $recipe" >&2; return 1; }

    formula="$(brew_resolve_formula "$recipe")" || return 1
    fingerprint="$(brew_formula_fingerprint "$(brew_source_of "$formula" | jq -r '.source_path')")" || return 1

    recipe_set_field "$file" BREW_FORMULA_REVIEWED "$fingerprint" || return 1
    log "${recipe}: reviewed against ${formula} as it stands today"
}

# Commit message for a sync, read from a report on stdin.
commit_message() {
    jq -r '
        [.recipes[] | select(.status == "updated")] as $updated
        | ($updated | length) as $n
        | "synchronise \($n) recipe\(if $n > 1 then "s" else "" end) avec brew",
          "",
          ($updated[] | "- \(.recipe) \(.from) -> \(.to)")
    '
}

# Record the synced recipes, reading the report from stdin. Does nothing when
# the working tree is clean, so a quiet day leaves no empty commit behind.
commit_sync() {
    local report message

    report="$(cat)"

    if git diff --quiet -- .github/scripts/recipes; then
        log "no recipe changed, nothing to commit"
        return 0
    fi

    message="$(printf '%s' "$report" | commit_message)"
    git add -- .github/scripts/recipes
    git -c "user.name=github-actions[bot]" \
        -c "user.email=41898282+github-actions[bot]@users.noreply.github.com" \
        commit -q -m "$message"
    log "committed: $(git log -1 --pretty=%s)"
}

# What in a report needs a human to decide something, as markdown. Empty when
# nothing does, so the caller can close the tracking issue instead of leaving a
# stale one open.
#
# The run summary is where these signals used to go, and nobody opens a run
# summary. An issue gets read.
attention() {
    jq -r '
        def rows(f): [.recipes[] | select(f)];

        (rows(.status == "unresolved")) as $orphans
        | (rows(.formula_changed == true)) as $moved
        | (rows((.patches_not_replayed // 0) > 0)) as $unpatched
        | (rows(.status == "failed")) as $failed
        | (.new_major_lines // []) as $lines

        | if (($orphans | length) + ($moved | length) + ($unpatched | length)
              + ($failed | length) + ($lines | length)) == 0
          then empty
          else
            ["The nightly sync is asking for decisions it will not take on its own.", ""]
            + (if ($orphans | length) > 0 then
                ["### Recipes tracking a line Homebrew no longer serves", "",
                 "These stopped receiving updates entirely.", ""]
                + [$orphans[] | "- `\(.recipe)`, pinned at \(.from)"] + [""]
               else [] end)
            + (if ($failed | length) > 0 then
                ["### Recipes the sync could not update", ""]
                + [$failed[] | "- `\(.recipe)`, still at \(.from), upstream is at \(.to)"] + [""]
               else [] end)
            + (if ($moved | length) > 0 then
                ["### Formulae whose build logic moved", "",
                 "Read the diff, carry over what matters into `build()`, then run `sync-upstream.sh review <recipe>`.", ""]
                + [$moved[] | "- `\(.recipe)`: https://github.com/Homebrew/homebrew-core/commits/master/\(.formula_path)"] + [""]
               else [] end)
            + (if ($lines | length) > 0 then
                ["### Major lines available upstream", "",
                 "Adding one is a product decision, so the sync reports them instead.", ""]
                + [$lines[] | "- `\(.)`"] + [""]
               else [] end)
            + (if ($unpatched | length) > 0 then
                ["### Recipes building the plain tarball while Homebrew patches it", "",
                 "Those patches live in the tap with no fetchable URL.", ""]
                + [$unpatched[] | "- `\(.recipe)`: \(.patches_not_replayed) patch(es)"] + [""]
               else [] end)
            | .[]
          end
    '
}

# Markdown digest of a report, for the job summary. Anything that did not go
# through is listed explicitly: a silent failure is the one that ships stale
# binaries for months.
summary() {
    jq -r '
        def rows($status): [.recipes[] | select(.status == $status)];
        "### Upstream sync",
        "",
        ([.recipes[] | select(.status == "updated" or .status == "outdated")] as $u
         | if ($u | length) == 0 then "No recipe needed an update."
           else "| Recipe | Formula | From | To |", "|---|---|---|---|",
                ($u[] | "| \(.recipe) | \(.formula) | \(.from) | \(.to) |")
           end),
        (rows("failed") as $f
         | if ($f | length) == 0 then empty
           else "", "**failed**, left untouched:",
                ($f[] | "- \(.recipe): could not sync to \(.to)")
           end),
        (rows("unresolved") as $o
         | if ($o | length) == 0 then empty
           else "", "**unresolved**, no Homebrew formula serves these lines:",
                ($o[] | "- \(.recipe) (pinned at \(.from))")
           end),
        ([.recipes[] | select(.formula_changed == true)] as $c
         | if ($c | length) == 0 then empty
           else "", "Formulae whose build logic moved since it was transposed. Review, adjust `build()` if needed, then `sync-upstream.sh review <recipe>`:",
                ($c[] | "- \(.recipe): https://github.com/Homebrew/homebrew-core/commits/master/\(.formula_path)")
           end),
        ([.recipes[] | select((.patches_not_replayed // 0) > 0)] as $d
         | if ($d | length) == 0 then empty
           else "", "Recipes building the plain tarball while Homebrew patches it:",
                ($d[] | "- \(.recipe): \(.patches_not_replayed) upstream patch(es) not replayed")
           end),
        (if (.new_major_lines | length) == 0 then empty
         else "", "New major lines available upstream: " + (.new_major_lines | join(", "))
         end)
    '
}

main() {
    local command="${1:-check}"

    case "$command" in
        check|apply) ;;
        review) shift; review_recipe "$@"; return $? ;;
        commit-message) commit_message; return 0 ;;
        commit) commit_sync; return 0 ;;
        summary) summary; return 0 ;;
        attention) attention; return 0 ;;
        *)
            echo "usage: $(basename "$0") {check|apply|review <recipe>|commit|commit-message|summary|attention}" >&2
            return 2
            ;;
    esac

    local entries=() new_lines=()
    local file entry recipe formula version package major candidate

    local -A covered=()
    for file in "${RECIPES_DIR}"/*.sh; do
        recipe="$(basename "$file" .sh)"
        covered["${recipe%@*}/$(line_major "$recipe" "$(recipe_field "$file" PACKAGE_VERSION)")"]=1
    done

    for file in "${RECIPES_DIR}"/*.sh; do
        entry="$(inspect_recipe "$file" "$command")"
        entries+=("$entry")

        formula="$(jq -r '.formula // empty' <<<"$entry")"
        [[ -n "$formula" ]] || continue
        recipe="$(jq -r '.recipe' <<<"$entry")"
        version="$(jq -r '.to' <<<"$entry")"
        while read -r package major candidate; do
            [[ -n "$candidate" ]] || continue
            [[ -n "${covered["${package}/${major}"]:-}" ]] && continue
            new_lines+=("$candidate")
        done < <(new_lines_for "$recipe" "$formula" "$version")
    done

    printf '%s\n' "${entries[@]}" \
        | jq -s --arg command "$command" \
               --argjson new_lines "$(printf '%s\n' "${new_lines[@]+"${new_lines[@]}"}" | jq -Rs 'split("\n") | map(select(. != "")) | unique')" \
               '{command: $command, recipes: ., new_major_lines: $new_lines}'
}

main "$@"
