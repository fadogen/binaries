#!/usr/bin/env bash
set -euo pipefail

# ================================
# SERVICES METADATA MANAGER
# ================================
# Manages metadata-services-{os}-{arch}.json for all database services
# Commands:
#   check-versions    - Compare metadata with recipe versions and generate build matrix
#   update-metadata   - Update metadata-services-{os}-{arch}.json with build results

# ================================
# CONFIGURATION
# ================================

# Source centralized services config
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
CONFIG_PATH="${SCRIPT_DIR}/../config/services-config.sh"
# shellcheck source=../config/services-config.sh
source "$CONFIG_PATH"

# Runners by OS and architecture
declare -A OS_ARCH_RUNNERS=(
    # macOS
    ["darwin-arm64"]="macos-26"
    ["darwin-x86_64"]="macos-15-intel"
    # Linux
    ["linux-arm64"]="ubuntu-24.04-arm"
    ["linux-x86_64"]="ubuntu-latest"
    # Windows
    ["windows-x86_64"]="windows-latest"
)

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

# Get metadata filename for a specific OS and architecture
get_metadata_file() {
    local os="$1"
    local arch="$2"
    echo "metadata-services-${os}-${arch}.json"
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

    # Log force rebuild services if set
    if [[ -n "${FORCE_REBUILD_SERVICES:-}" ]]; then
        log_info "Force rebuild requested for: $FORCE_REBUILD_SERVICES"
    fi

    # Load metadata for each OS/architecture combination
    declare -A metadata_by_os_arch
    for os in $SUPPORTED_OS; do
        local archs
        archs=$(get_architectures_for_os "$os")
        for arch in $archs; do
            local key="${os}-${arch}"
            local metadata_file
            metadata_file=$(get_metadata_file "$os" "$arch")
            if [[ -f "$metadata_file" ]]; then
                metadata_by_os_arch[$key]=$(cat "$metadata_file")
                log_info "Loaded existing metadata for $key"
            else
                metadata_by_os_arch[$key]='{}'
                log_info "No metadata found for $key (will create)"
            fi
        done
    done

    # Build matrix array
    local matrix_items=()

    # Filter services if FILTER_SERVICE is set
    local base_services="$AVAILABLE_SERVICES"
    if [[ -n "${FILTER_SERVICE:-}" ]]; then
        base_services="$FILTER_SERVICE"
        log_info "Filtering for service: $FILTER_SERVICE"
    fi

    # Filter OS if FILTER_OS is set
    local os_to_check="$SUPPORTED_OS"
    if [[ -n "${FILTER_OS:-}" ]]; then
        os_to_check="$FILTER_OS"
        log_info "Filtering for OS: $FILTER_OS"
    fi

    # Iterate over all OS
    for os in $os_to_check; do
        # Get services and architectures for this OS
        local services_for_os
        services_for_os=$(get_services_for_os "$os")
        local archs_for_os
        archs_for_os=$(get_architectures_for_os "$os")

        # Filter services
        local services_to_check=""
        for service in $base_services; do
            if is_service_supported_on_os "$service" "$os"; then
                services_to_check="$services_to_check $service"
            fi
        done

        # Iterate over all services for this OS
        for service in $services_to_check; do
            # Get supported major versions for this service (filtered by OS)
            local major_versions
            major_versions=$(get_supported_versions "$service" "$os")

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

                # Check each architecture for this OS
                for arch in $archs_for_os; do
                    local key="${os}-${arch}"
                    local metadata="${metadata_by_os_arch[$key]}"
                    local runs_on="${OS_ARCH_RUNNERS[$key]}"

                    # Get current version from metadata (if exists)
                    local metadata_latest
                    metadata_latest=$(echo "$metadata" | jq -r ".\"$service\".\"$major\".latest // \"\"")

                    # Check if force rebuild is requested for this service
                    local force_rebuild=false
                    if [[ -n "${FORCE_REBUILD_SERVICES:-}" ]]; then
                        for force_svc in $FORCE_REBUILD_SERVICES; do
                            # Match "service" or "service@major"
                            if [[ "$force_svc" == "$service" || "$force_svc" == "${service}@${major}" ]]; then
                                force_rebuild=true
                                break
                            fi
                        done
                    fi

                    # Compare versions (or force rebuild)
                    if [[ "$recipe_version" != "$metadata_latest" || "$force_rebuild" == "true" ]]; then
                        if [[ "$force_rebuild" == "true" ]]; then
                            log_info "Force: ${service} ${major} ${os}/${arch} -> ${recipe_version}"
                        elif [[ -z "$metadata_latest" ]]; then
                            log_info "New: ${service} ${major} ${os}/${arch} -> ${recipe_version}"
                        else
                            log_info "Update: ${service} ${major} ${os}/${arch} -> ${recipe_version} (was: ${metadata_latest})"
                        fi

                        # Add to build matrix with all info
                        matrix_items+=("{\"service\": \"$service\", \"version\": \"$recipe_version\", \"major\": \"$major\", \"recipe\": \"$recipe_name\", \"os\": \"$os\", \"arch\": \"$arch\", \"runs-on\": \"$runs_on\"}")
                    fi
                done
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
        # Sort matrix: MySQL first (slowest build), then by OS, then by service
        local matrix_items_str
        matrix_items_str=$(printf '%s\n' "${matrix_items[@]}" | \
            jq -s 'sort_by(.os, .service) | sort_by(if .service == "mysql" then 0 else 1 end)' | \
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
    local os="${1:-}"
    local arch="${2:-}"
    if [[ -z "$os" || -z "$arch" ]]; then
        log_error "Usage: update-metadata <os> <arch>"
    fi

    local metadata_file
    metadata_file=$(get_metadata_file "$os" "$arch")

    # Load existing metadata or create new
    local metadata='{}'
    if [[ -f "$metadata_file" ]]; then
        metadata=$(cat "$metadata_file")
    fi

    # Read checksums from stdin (format: service,version,major,sha256,filename)
    local checksums_input
    checksums_input=$(cat)

    if [[ -z "$checksums_input" ]]; then
        log_info "No checksums provided for $os/$arch (skipping)"
        return 0
    fi

    # Process each checksum line
    while IFS=',' read -r service version major sha256 filename; do
        [[ -z "$service" ]] && continue

        log_info "Updating $service $major ($os/$arch): $version"

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
            log_error "Usage: $0 {check-versions|update-metadata <os> <arch>}"
            ;;
    esac
}

main "$@"
