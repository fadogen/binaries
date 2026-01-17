#!/usr/bin/env bash
# ================================
# CONFIGURATION CENTRALISÉE DES SERVICES
# ================================
# Source unique de vérité pour toutes les versions supportées
# Utilisé par : services-metadata-manager.sh, service-build.sh

# Liste des services disponibles
AVAILABLE_SERVICES="mariadb mysql postgresql redis valkey"

# Services qui ne conservent qu'UNE seule version majeure à la fois
# Quand une nouvelle version majeure est buildée, les anciennes sont supprimées
SINGLE_VERSION_SERVICES="valkey"

# ================================
# CONFIGURATION MULTI-OS
# ================================

# OS supportés (Windows désactivé pour le moment)
SUPPORTED_OS="darwin linux"

# Architectures par OS
get_architectures_for_os() {
    local os="$1"
    case "$os" in
        darwin|linux) echo "arm64 x86_64" ;;
        *) echo "" ;;
    esac
}

# Services disponibles par OS
get_services_for_os() {
    local os="$1"
    case "$os" in
        darwin) echo "mariadb mysql postgresql redis valkey" ;;
        linux) echo "mariadb postgresql redis valkey" ;;
        *) echo "" ;;
    esac
}

# Vérifier si un service est supporté sur un OS donné
is_service_supported_on_os() {
    local service="$1"
    local os="$2"

    local services
    services=$(get_services_for_os "$os")
    [[ " $services " =~ \ $service\  ]]
}

# Vérifier si un service est single-version
is_single_version_service() {
    local service="$1"
    [[ -z "$service" ]] && return 1
    [[ " $SINGLE_VERSION_SERVICES " =~ \ $service\  ]]
}

# Fonction utilitaire : obtenir les versions supportées pour un service
get_supported_versions() {
    local service="$1"
    local os="${2:-}"  # OS optionnel pour filtrer les versions

    if [[ -z "$service" ]]; then
        echo "Usage: get_supported_versions <service> [os]" >&2
        return 1
    fi

    local versions=""
    case "$service" in
        "mariadb")
            if [[ "$os" == "linux" ]]; then
                versions="11 12"
            else
                versions="10 11 12"
            fi
            ;;
        "mysql")
            versions="8 9"
            ;;
        "postgresql")
            # Toutes les versions supportées sur les deux plateformes
            versions="14 15 16 17 18"
            ;;
        "redis")
            versions="8"
            ;;
        "valkey")
            versions="9"
            ;;
        *)
            versions=""
            ;;
    esac

    echo "$versions"
}

# Fonction utilitaire : vérifier si une version est supportée
is_version_supported() {
    local service="$1"
    local version="$2"

    if [[ -z "$service" || -z "$version" ]]; then
        echo "Usage: is_version_supported <service> <version>" >&2
        return 1
    fi

    local supported_versions
    supported_versions=$(get_supported_versions "$service")

    if [[ " $supported_versions " =~ \ $version\  ]]; then
        return 0  # Version supportée
    else
        return 1  # Version non supportée
    fi
}

# Fonction utilitaire : obtenir la recipe correspondant à un service et une version majeure
get_recipe_for_service_major() {
    local service="$1"
    local major="$2"

    if [[ -z "$service" || -z "$major" ]]; then
        echo "Usage: get_recipe_for_service_major <service> <major>" >&2
        return 1
    fi

    # Déterminer le chemin vers les recipes
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local recipes_dir="${script_dir}/../scripts/recipes"

    # 1. Chercher pattern {service}@{major}.*.sh (ex: mysql@8.4.sh, mariadb@10.11.sh)
    local recipe_file
    recipe_file=$(find "$recipes_dir" -maxdepth 1 -name "${service}@${major}.*.sh" 2>/dev/null | head -1)

    if [[ -n "$recipe_file" ]]; then
        basename "$recipe_file" .sh
        return 0
    fi

    # 2. Chercher pattern {service}@{major}.sh (ex: postgresql@14.sh)
    if [[ -f "${recipes_dir}/${service}@${major}.sh" ]]; then
        echo "${service}@${major}"
        return 0
    fi

    # 3. Chercher pattern {service}.sh (ex: valkey.sh) - seulement si major correspond
    # Cette règle s'applique quand le service utilise la formule principale
    if [[ -f "${recipes_dir}/${service}.sh" ]]; then
        echo "${service}"
        return 0
    fi

    # Aucune recipe trouvée
    return 1
}

# Fonction utilitaire : afficher toutes les configurations
show_all_configs() {
    echo "=== CONFIGURATION DES SERVICES ==="
    for service in $AVAILABLE_SERVICES; do
        local versions
        versions=$(get_supported_versions "$service")
        echo "$service: $versions"
    done
}

# Si le script est exécuté directement (pour debug)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_all_configs
fi
