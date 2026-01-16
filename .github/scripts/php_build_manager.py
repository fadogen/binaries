#!/usr/bin/env python3
"""
Unified PHP build manager for static-php-cli CI/CD.
Handles version checking, archive creation, metadata updates, and EOL cleanup.
"""

import json
import argparse
import tarfile
import subprocess
from pathlib import Path

FRANKENPHP_VERSIONS_FILE = 'frankenphp_versions.txt'
ALL_OS = ['darwin', 'linux']
ALL_ARCHS = ['arm64', 'x86_64']

TARGET_CONFIG = {
    ('darwin', 'arm64'): {'runner': 'macos-26', 'spc_binary': 'spc-macos-aarch64'},
    ('darwin', 'x86_64'): {'runner': 'macos-15-intel', 'spc_binary': 'spc-macos-x86_64'},
    ('linux', 'arm64'): {'runner': 'ubuntu-24.04-arm', 'spc_binary': 'spc-linux-aarch64'},
    ('linux', 'x86_64'): {'runner': 'ubuntu-24.04', 'spc_binary': 'spc-linux-x86_64'},
}


def get_metadata_file(os_name, arch):
    """Get metadata filename for a specific os+architecture."""
    return f'metadata-php-{os_name}-{arch}.json'


def load_json(filepath):
    """Load JSON file."""
    with open(filepath, 'r') as f:
        return json.load(f)


def save_json(data, filepath):
    """Save JSON file with pretty formatting."""
    with open(filepath, 'w') as f:
        json.dump(data, f, indent=2)


def get_archive_filename(full_version, os_name, arch):
    """Generate filename with os and architecture suffix."""
    return f"php-{full_version}-{os_name}-{arch}.tar.gz"


def fetch_version_details(version):
    """Fetch detailed version info from PHP.net API."""
    url = f"https://www.php.net/releases/index.php?json&version={version}"
    result = subprocess.run(['curl', '-fsSL', url], capture_output=True, text=True)
    if result.returncode == 0:
        return json.loads(result.stdout)
    return None


def check_versions():
    """Check PHP versions and generate build matrix."""
    api_data = load_json('api_response.json')

    # Load metadata for all os+arch combinations
    metadata_by_target = {}
    for os_name in ALL_OS:
        for arch in ALL_ARCHS:
            key = (os_name, arch)
            metadata_file = get_metadata_file(os_name, arch)
            if Path(metadata_file).exists():
                metadata_by_target[key] = load_json(metadata_file)
            else:
                metadata_by_target[key] = {}

    build_matrix = []
    eol_versions = []

    # Get allowed versions from serversideup FrankenPHP config
    if Path(FRANKENPHP_VERSIONS_FILE).exists():
        with open(FRANKENPHP_VERSIONS_FILE, 'r') as f:
            allowed_versions = [v.strip() for v in f.read().strip().split(',') if v.strip()]
        print(f"Allowed PHP versions from serversideup: {allowed_versions}")
    else:
        # Fallback: use existing metadata keys if available (from any target)
        all_keys = set()
        for target_metadata in metadata_by_target.values():
            all_keys.update(target_metadata.keys())
        if all_keys:
            allowed_versions = list(all_keys)
            print(f"Warning: FrankenPHP versions file not found, using existing metadata keys: {allowed_versions}")
        else:
            raise RuntimeError("Cannot determine allowed PHP versions: serversideup config unavailable and no existing metadata")

    supported_versions = []
    if "8" in api_data:
        all_supported = api_data["8"].get("supported_versions", [])
        supported_versions = [v for v in all_supported if v in allowed_versions]
        print(f"Filtered supported versions: {supported_versions} (from {all_supported})")

    # TEMPORARY: Only build PHP 8.4 for debugging
    supported_versions = [v for v in supported_versions if v == "8.4"]
    print(f"DEBUG: Restricted to PHP 8.4 only: {supported_versions}")

    version_details_cache = {}
    print("Fetching version details for all supported versions...")
    for version_branch in supported_versions:
        version_details = fetch_version_details(version_branch)
        if version_details:
            version_name = version_details.get('version')
            if version_name:
                version_details_cache[version_name] = version_details
                print(f"Cached details for {version_name}")
        else:
            print(f"Failed to fetch details for {version_branch}")

    for full_version, version_details in version_details_cache.items():
        version_parts = full_version.split('.')
        if len(version_parts) >= 2:
            major_minor = f"{version_parts[0]}.{version_parts[1]}"
        else:
            major_minor = full_version

        api_release = version_details.get('date', '')

        # Check each os+arch combination independently
        for (os_name, arch), config in TARGET_CONFIG.items():
            # TEMPORARY: Only build linux/arm64 for debugging
            if os_name != 'linux' or arch != 'arm64':
                continue

            key = (os_name, arch)
            metadata = metadata_by_target[key]
            need_build = False

            if major_minor not in metadata:
                need_build = True
                print(f"New version detected: {full_version} ({os_name}/{arch})")
            else:
                metadata_release = metadata[major_minor].get('releaseDate', '')
                if api_release != metadata_release:
                    need_build = True
                    print(f"Updated version detected: {full_version} ({os_name}/{arch})")

            if need_build:
                build_matrix.append({
                    'php-version': major_minor,
                    'full-version': full_version,
                    'os': os_name,
                    'arch': arch,
                    'runs-on': config['runner'],
                    'spc-binary': config['spc_binary'],
                    'releaseDate': api_release
                })

    # Collect EOL versions from all targets
    all_metadata_keys = set()
    for target_metadata in metadata_by_target.values():
        all_metadata_keys.update(target_metadata.keys())

    for major_minor in all_metadata_keys:
        if major_minor not in supported_versions:
            eol_versions.append(major_minor)
            print(f"EOL version detected: {major_minor}")

    matrix_json = json.dumps({'include': build_matrix})
    eol_json = json.dumps(eol_versions)
    should_build = 'true' if build_matrix else 'false'

    print(f"Build matrix: {len(build_matrix)} items")
    print(f"EOL versions: {len(eol_versions)} items")

    with open('github_output.txt', 'w') as f:
        f.write(f'matrix={matrix_json}\n')
        f.write(f'eol={eol_json}\n')
        f.write(f'should-build={should_build}\n')
        f.write(f'supported-versions={json.dumps(supported_versions)}\n')


def create_archive(php_version, os_name, arch):
    """Create tar.gz archive containing CLI, FPM binaries and shared extensions."""
    archive_name = get_archive_filename(php_version, os_name, arch)

    with tarfile.open(archive_name, 'w:gz') as tar:
        tar.add('buildroot/bin/php', arcname='php-cli')
        tar.add('buildroot/bin/php-fpm', arcname='php-fpm')

        # Include shared extensions (.so files) if they exist
        buildroot = Path('buildroot')
        for so_file in buildroot.rglob('*.so'):
            arcname = f'extensions/{so_file.name}'
            tar.add(str(so_file), arcname=arcname)
            print(f"Included {so_file.name} in archive")

    with open('archive_info.txt', 'w') as f:
        f.write(f'ARCHIVE_NAME={archive_name}\n')

    print(f"Created {archive_name}")


def update_metadata(build_matrix_json, archive_checksums, supported_versions_json):
    """Update metadata files per os+architecture with build results."""
    build_matrix = json.loads(build_matrix_json)
    supported_versions = json.loads(supported_versions_json)

    # Parse checksums: format is "version,os,arch,sha256,filename"
    checksums_map = {}
    for line in archive_checksums.strip().split('\n'):
        if line:
            parts = line.split(',')
            if len(parts) != 5:
                raise ValueError(f"Invalid checksum format - expected version,os,arch,sha256,filename: {line}")

            version, os_name, arch, sha256, filename = parts
            key = (os_name, arch)
            if key not in checksums_map:
                checksums_map[key] = {}
            checksums_map[key][version] = {
                'sha256': sha256,
                'filename': filename
            }

    # Update metadata per os+architecture
    for os_name in ALL_OS:
        for arch in ALL_ARCHS:
            key = (os_name, arch)
            metadata_file = get_metadata_file(os_name, arch)
            metadata = load_json(metadata_file) if Path(metadata_file).exists() else {}

            for build in build_matrix.get('include', []):
                if build.get('os') != os_name or build.get('arch') != arch:
                    continue

                major_minor = build['php-version']
                full_version = build['full-version']

                if key not in checksums_map or full_version not in checksums_map[key]:
                    print(f"Skipping {full_version} ({os_name}/{arch}) - no checksum (build may have failed)")
                    continue

                release_date = build.get('releaseDate', '')
                checksum_data = checksums_map[key][full_version]

                metadata[major_minor] = {
                    'latest': full_version,
                    'releaseDate': release_date,
                    'filename': checksum_data['filename'],
                    'sha256': checksum_data['sha256'],
                    'isEol': major_minor not in supported_versions
                }

                print(f"Updated {major_minor} ({os_name}/{arch}) -> {full_version}")

            # Update isEol for all existing versions
            for version_key in metadata:
                metadata[version_key]['isEol'] = version_key not in supported_versions

            save_json(metadata, metadata_file)
            print(f"Updated {metadata_file} for {len(metadata)} PHP versions")


def cleanup_eol(eol_versions_json):
    """Remove EOL versions from metadata files for all os+architectures."""
    eol_versions = json.loads(eol_versions_json)

    for os_name in ALL_OS:
        for arch in ALL_ARCHS:
            metadata_file = get_metadata_file(os_name, arch)
            if not Path(metadata_file).exists():
                continue

            metadata = load_json(metadata_file)
            removed_count = 0

            for version in eol_versions:
                if version in metadata:
                    del metadata[version]
                    print(f"Removed {version} from {metadata_file}")
                    removed_count += 1

            save_json(metadata, metadata_file)
            print(f"Removed {removed_count} EOL versions from {metadata_file}")


def main():
    parser = argparse.ArgumentParser(description='PHP build manager')
    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    subparsers.add_parser('check-versions', help='Check PHP versions and generate build matrix')

    archive_parser = subparsers.add_parser('create-archive', help='Create tar.gz archive with CLI and FPM')
    archive_parser.add_argument('--php-version', required=True, help='PHP version')
    archive_parser.add_argument('--os', required=True, help='Operating system (darwin or linux)')
    archive_parser.add_argument('--arch', required=True, help='Architecture (arm64 or x86_64)')

    metadata_parser = subparsers.add_parser('update-metadata', help='Update metadata-php.json with build results')
    metadata_parser.add_argument('--build-matrix', required=True, help='JSON build matrix')
    metadata_parser.add_argument('--archive-checksums', required=True, help='Archive checksums (version,os,arch,sha256,filename format)')
    metadata_parser.add_argument('--supported-versions', required=True, help='JSON array of supported PHP versions')

    cleanup_parser = subparsers.add_parser('cleanup-eol', help='Remove EOL versions from metadata')
    cleanup_parser.add_argument('--eol-versions', required=True, help='JSON array of EOL versions')

    args = parser.parse_args()

    if args.command == 'check-versions':
        check_versions()
    elif args.command == 'create-archive':
        create_archive(args.php_version, args.os, args.arch)
    elif args.command == 'update-metadata':
        update_metadata(args.build_matrix, args.archive_checksums, args.supported_versions)
    elif args.command == 'cleanup-eol':
        cleanup_eol(args.eol_versions)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
