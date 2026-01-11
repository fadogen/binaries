#!/usr/bin/env bash
set -euo pipefail

# ================================
# SERVICES METADATA MANAGER
# ================================
# Manages metadata-services-{arch}.json for all database services
# Commands:
#   check-versions    - Compare metadata with recipe versions and generate build matrix
#   update-metadata   - Update metadata-services-{arch}.json with build results

# ================================
# CONFIGURATION
# ================================

# Source centralized services config
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
CONFIG_PATH="${SCRIPT_DIR}/../config/services-config.sh"
# shellcheck source=../config/services-config.sh
source "$CONFIG_PATH"

# Supported architectures and their runners
declare -A ARCH_RUNNERS=(
    ["arm64"]="macos-26"
    ["x86_64"]="macos-15-intel"
)
SUPPORTED_ARCHS="arm64 x86_64"

# ================================
# UTILITY FUNCTIONS
# ================================

log_info() {
    echo "[INFO] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
    exit 1
}

check_prerequisites() {
    command -v jq >/dev/null 2>&1 || log_error "jq is required but not installed"
}

# Get metadata filename for a specific architecture
get_metadata_file() {
    local arch="$1"
    echo "metadata-services-${arch}.json"
}

# ================================
# RECIPE VERSION EXTRACTION
# ================================

get_version_from_recipe() {
    local recipe_name="$1"

    if [[ -z "$recipe_name" ]]; then
        log_error "Recipe name required"
    fi

    local recipe_file="${SCRIPT_DIR}/recipes/${recipe_name}.sh"

    if [[ ! -f "$recipe_file" ]]; then
        log_error "Recipe not found: $recipe_file"
    fi

    # Extract PACKAGE_VERSION from recipe file
    local version
    # shellcheck disable=SC1090
    version=$(source "$recipe_file" && echo "$PACKAGE_VERSION")

    if [[ -z "$version" ]]; then
        log_error "Could not extract PACKAGE_VERSION from $recipe_file"
    fi

    echo "$version"
}

# ================================
# CHECK VERSIONS COMMAND
# ================================

check_versions() {
    log_info "Checking service versions..."

    # Load metadata for each architecture
    declare -A metadata_by_arch
    for arch in $SUPPORTED_ARCHS; do
        local metadata_file
        metadata_file=$(get_metadata_file "$arch")
        if [[ -f "$metadata_file" ]]; then
            metadata_by_arch[$arch]=$(cat "$metadata_file")
            log_info "Loaded existing metadata for $arch"
        else
            metadata_by_arch[$arch]='{}'
            log_info "No metadata found for $arch (will create)"
        fi
    done

    # Build matrix array
    local matrix_items=()

    # Filter services if FILTER_SERVICE is set
    local services_to_check="$AVAILABLE_SERVICES"
    if [[ -n "${FILTER_SERVICE:-}" ]]; then
        services_to_check="$FILTER_SERVICE"
        log_info "Filtering for service: $FILTER_SERVICE"
    fi

    # Iterate over all services
    for service in $services_to_check; do
        # Get supported major versions for this service
        local major_versions
        major_versions=$(get_supported_versions "$service")

        # Check each major version
        for major in $major_versions; do
            # Check if a recipe exists for this service+major
            local recipe_name
            recipe_name=$(get_recipe_for_service_major "$service" "$major")

            if [[ $? -ne 0 || -z "$recipe_name" ]]; then
                log_info "Skip: $service $major (no recipe available)"
                continue
            fi

            # Get version from recipe
            local recipe_version
            recipe_version=$(get_version_from_recipe "$recipe_name")

            if [[ $? -ne 0 || -z "$recipe_version" ]]; then
                log_info "Skip: $service $major (could not extract version from recipe)"
                continue
            fi

            # Check each architecture
            for arch in $SUPPORTED_ARCHS; do
                local metadata="${metadata_by_arch[$arch]}"
                local runs_on="${ARCH_RUNNERS[$arch]}"

                # Get current version from metadata (if exists)
                local metadata_latest
                metadata_latest=$(echo "$metadata" | jq -r ".\"$service\".\"$major\".latest // \"\"")

                # Compare versions
                if [[ "$recipe_version" != "$metadata_latest" ]]; then
                    if [[ -z "$metadata_latest" ]]; then
                        log_info "New: ${service} ${major} ${arch} -> ${recipe_version}"
                    else
                        log_info "Update: ${service} ${major} ${arch} -> ${recipe_version} (was: ${metadata_latest})"
                    fi

                    # Add to build matrix with recipe name, arch, and runs-on
                    matrix_items+=("{\"service\": \"$service\", \"version\": \"$recipe_version\", \"major\": \"$major\", \"recipe\": \"$recipe_name\", \"arch\": \"$arch\", \"runs-on\": \"$runs_on\"}")
                fi
            done
        done
    done

    # Build matrix JSON
    local matrix_json
    if [[ ${#matrix_items[@]} -eq 0 ]]; then
        matrix_json='{"include":[]}'
        echo "should-build=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
        log_info "No builds needed"
    else
        # Sort matrix: MySQL first (slowest build), then others alphabetically
        local matrix_items_str
        matrix_items_str=$(printf '%s\n' "${matrix_items[@]}" | \
            jq -s 'sort_by(.service) | sort_by(if .service == "mysql" then 0 else 1 end)' | \
            jq -c '.[]' | tr '\n' ',' | sed 's/,$//')
        matrix_json=$(echo "{\"include\": [$matrix_items_str]}" | jq -c)
        echo "should-build=true" >> "${GITHUB_OUTPUT:-/dev/stdout}"
        log_info "Build matrix generated with ${#matrix_items[@]} items (MySQL prioritized)"
    fi

    echo "build-matrix=$matrix_json" >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

# ================================
# UPDATE METADATA COMMAND
# ================================

update_metadata() {
    local arch="${1:-}"
    if [[ -z "$arch" ]]; then
        log_error "Usage: update-metadata <arch>"
    fi

    local metadata_file
    metadata_file=$(get_metadata_file "$arch")

    # Load existing metadata or create new
    local metadata='{}'
    if [[ -f "$metadata_file" ]]; then
        metadata=$(cat "$metadata_file")
    fi

    # Read checksums from stdin (format: service,version,major,sha256,filename)
    local checksums_input
    checksums_input=$(cat)

    if [[ -z "$checksums_input" ]]; then
        log_info "No checksums provided for $arch (skipping)"
        return 0
    fi

    # Process each checksum line
    while IFS=',' read -r service version major sha256 filename; do
        [[ -z "$service" ]] && continue

        log_info "Updating $service $major ($arch): $version"

        # Update metadata using jq
        metadata=$(echo "$metadata" | jq -c \
            --arg service "$service" \
            --arg major "$major" \
            --arg latest "$version" \
            --arg sha256 "$sha256" \
            --arg filename "$filename" \
            '.[$service][$major] = {
                "latest": $latest,
                "sha256": $sha256,
                "filename": $filename
            }')
    done <<< "$checksums_input"

    # Cleanup single-version services: remove old major versions
    for service in $SINGLE_VERSION_SERVICES; do
        is_single_version_service "$service" || continue

        local current_major
        current_major=$(get_supported_versions "$service" | tr ' ' '\n' | head -1)
        [[ -z "$current_major" ]] && continue

        # Get all major versions in metadata for this service
        local old_majors
        old_majors=$(echo "$metadata" | jq -r ".\"$service\" // {} | keys[]" 2>/dev/null)

        # Remove all majors except the current one
        for old_major in $old_majors; do
            if [[ "$old_major" != "$current_major" ]]; then
                log_info "Cleanup: removing $service.$old_major (keeping only $current_major)"
                metadata=$(echo "$metadata" | jq "del(.\"$service\".\"$old_major\")")
            fi
        done
    done

    # Save updated metadata
    echo "$metadata" | jq '.' > "$metadata_file"
    log_info "Metadata updated: $metadata_file"
}

# ================================
# MAIN
# ================================

main() {
    check_prerequisites

    local command="${1:-}"
    case "$command" in
        check-versions)
            check_versions
            ;;
        update-metadata)
            shift
            update_metadata "$@"
            ;;
        *)
            log_error "Usage: $0 {check-versions|update-metadata <arch>}"
            ;;
    esac
}

main "$@"
