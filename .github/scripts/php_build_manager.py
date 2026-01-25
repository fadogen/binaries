#!/usr/bin/env python3
"""
Unified PHP build manager for static-php-cli CI/CD.
Handles version checking, archive creation, metadata updates, and EOL cleanup.
"""

import json
import argparse
import tarfile
import zipfile
import shutil
import subprocess
import urllib.request
from pathlib import Path

FRANKENPHP_VERSIONS_FILE = 'frankenphp_versions.txt'
ALL_OS = ['darwin', 'linux']
ALL_ARCHS = ['arm64', 'x86_64']

# Windows configuration
WINDOWS_OS = 'windows'
WINDOWS_ARCH = 'x86_64'
WINDOWS_RUNNER = 'ubuntu-latest'
WINDOWS_DOWNLOADS_URL = 'https://windows.php.net/downloads/releases'

# VS version mapping (vs16 = VS2019, vs17 = VS2022)
VS_VERSION_MAP = {
    '8.1': 'vs16', '8.2': 'vs16', '8.3': 'vs16',
    '8.4': 'vs17', '8.5': 'vs17',
}

# Xdebug configuration
XDEBUG_VERSION = '3.5.0'
XDEBUG_BASE_URL = 'https://xdebug.org/files'

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


def get_vs_version(php_version):
    """Get Visual Studio version for a PHP version."""
    return VS_VERSION_MAP.get(php_version, 'vs17')


def get_windows_php_url(full_version, php_version):
    """Generate Windows PHP download URL."""
    vs = get_vs_version(php_version)
    return f"{WINDOWS_DOWNLOADS_URL}/php-{full_version}-nts-Win32-{vs}-x64.zip"


def get_xdebug_url(php_version):
    """Generate Xdebug DLL download URL for Windows."""
    vs = get_vs_version(php_version)
    return f"{XDEBUG_BASE_URL}/php_xdebug-{XDEBUG_VERSION}-{php_version}-nts-{vs}-x86_64.dll"


def get_windows_archive_filename(full_version):
    """Generate Windows archive filename (ZIP format)."""
    return f"php-{full_version}-{WINDOWS_OS}-{WINDOWS_ARCH}.zip"


def get_major_minor(full_version):
    """Extract major.minor from full version string."""
    parts = full_version.split('.')
    return f"{parts[0]}.{parts[1]}" if len(parts) >= 2 else full_version


def check_xdebug_available(php_version):
    """Check if Xdebug is available for a PHP version via HEAD request."""
    url = get_xdebug_url(php_version)
    result = subprocess.run(
        ['curl', '-fsSL', '-I', '--head', url],
        capture_output=True, text=True
    )
    return result.returncode == 0


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

    # Load metadata for all os+arch combinations (Unix)
    metadata_by_target = {}
    for os_name in ALL_OS:
        for arch in ALL_ARCHS:
            key = (os_name, arch)
            metadata_file = get_metadata_file(os_name, arch)
            if Path(metadata_file).exists():
                metadata_by_target[key] = load_json(metadata_file)
            else:
                metadata_by_target[key] = {}

    # Load Windows metadata
    windows_metadata_file = get_metadata_file(WINDOWS_OS, WINDOWS_ARCH)
    windows_metadata = load_json(windows_metadata_file) if Path(windows_metadata_file).exists() else {}

    # Load Windows releases.json to verify availability
    windows_releases = {}
    if Path('windows_releases.json').exists():
        windows_releases = load_json('windows_releases.json')
        print(f"Loaded Windows releases.json with {len(windows_releases)} versions")

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
        major_minor = get_major_minor(full_version)
        api_release = version_details.get('date', '')

        # Check each os+arch combination independently
        for (os_name, arch), config in TARGET_CONFIG.items():
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

    # Windows matrix generation - use versions from windows.php.net, not php.net
    windows_matrix = []
    for major_minor in supported_versions:
        # Check if version is available on windows.php.net
        if not windows_releases or major_minor not in windows_releases:
            print(f"PHP {major_minor} not available on Windows, skipping")
            continue

        # Get version info from windows.php.net releases.json
        win_version_info = windows_releases[major_minor]
        full_version = win_version_info.get('version')
        if not full_version:
            print(f"PHP {major_minor} has no version in Windows releases, skipping")
            continue

        # Windows releases.json doesn't have release dates, so we use the version as key
        need_build = False
        if major_minor not in windows_metadata:
            need_build = True
            print(f"New Windows version detected: {full_version}")
        else:
            metadata_version = windows_metadata[major_minor].get('latest', '')
            if full_version != metadata_version:
                need_build = True
                print(f"Updated Windows version detected: {full_version} (was {metadata_version})")

        if need_build:
            windows_matrix.append({
                'php-version': major_minor,
                'full-version': full_version,
                'runs-on': WINDOWS_RUNNER
            })

    matrix_json = json.dumps({'include': build_matrix})
    windows_matrix_json = json.dumps({'include': windows_matrix})
    eol_json = json.dumps(eol_versions)
    should_build = 'true' if build_matrix else 'false'
    should_build_windows = 'true' if windows_matrix else 'false'

    print(f"Build matrix: {len(build_matrix)} items")
    print(f"Windows matrix: {len(windows_matrix)} items")
    print(f"EOL versions: {len(eol_versions)} items")

    with open('github_output.txt', 'w') as f:
        f.write(f'matrix={matrix_json}\n')
        f.write(f'windows-matrix={windows_matrix_json}\n')
        f.write(f'eol={eol_json}\n')
        f.write(f'should-build={should_build}\n')
        f.write(f'should-build-windows={should_build_windows}\n')
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


def create_windows_archive(php_version, full_version):
    """Download PHP Windows binaries and Xdebug, create ZIP archive."""
    work_dir = Path('windows_build')
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir()

    try:
        # Download PHP
        php_url = get_windows_php_url(full_version, php_version)
        php_zip_path = work_dir / 'php_original.zip'
        print(f"Downloading PHP from {php_url}")
        urllib.request.urlretrieve(php_url, php_zip_path)

        # Check Xdebug availability and download if available
        xdebug_available = check_xdebug_available(php_version)
        xdebug_path = None
        if xdebug_available:
            xdebug_url = get_xdebug_url(php_version)
            xdebug_path = work_dir / 'php_xdebug.dll'
            print(f"Downloading Xdebug from {xdebug_url}")
            urllib.request.urlretrieve(xdebug_url, xdebug_path)
        else:
            print(f"WARNING: Xdebug not available for PHP {php_version}, creating archive without Xdebug")

        # Extract PHP
        extract_dir = work_dir / 'extracted'
        with zipfile.ZipFile(php_zip_path, 'r') as zf:
            zf.extractall(extract_dir)

        # Find the extracted PHP directory
        php_source_dirs = [d for d in extract_dir.iterdir() if d.is_dir()]
        if not php_source_dirs:
            # Files might be directly in extract_dir
            php_source = extract_dir
        else:
            php_source = php_source_dirs[0]

        # Create output structure: php-{version}/
        output_dir = work_dir / f'php-{full_version}'
        output_dir.mkdir()

        # Copy php.exe as php-cli.exe
        php_exe = php_source / 'php.exe'
        if php_exe.exists():
            shutil.copy(php_exe, output_dir / 'php-cli.exe')
            print("Copied php.exe -> php-cli.exe")

        # Copy php-cgi.exe
        php_cgi = php_source / 'php-cgi.exe'
        if php_cgi.exists():
            shutil.copy(php_cgi, output_dir / 'php-cgi.exe')
            print("Copied php-cgi.exe")

        # Copy all root DLLs (runtime dependencies)
        for dll in php_source.glob('*.dll'):
            shutil.copy(dll, output_dir / dll.name)
        print(f"Copied {len(list(php_source.glob('*.dll')))} DLL files")

        # Copy ext/ directory with extensions
        ext_source = php_source / 'ext'
        ext_dest = output_dir / 'ext'
        if ext_source.exists():
            shutil.copytree(ext_source, ext_dest)
            print(f"Copied ext/ directory with {len(list(ext_source.glob('*.dll')))} extensions")
        else:
            ext_dest.mkdir()

        # Add Xdebug to ext/ if available
        if xdebug_path and xdebug_path.exists():
            shutil.copy(xdebug_path, ext_dest / 'php_xdebug.dll')
            print("Added Xdebug to ext/")

        # Create final ZIP archive
        archive_name = get_windows_archive_filename(full_version)
        with zipfile.ZipFile(archive_name, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for file_path in output_dir.rglob('*'):
                if file_path.is_file():
                    arcname = file_path.relative_to(work_dir)
                    zf.write(file_path, arcname)

        # Write archive info with xdebug version
        xdebug_info = XDEBUG_VERSION if xdebug_available else ''
        with open('archive_info.txt', 'w') as f:
            f.write(f'ARCHIVE_NAME={archive_name}\n')
            f.write(f'XDEBUG_VERSION={xdebug_info}\n')

        print(f"Created {archive_name}")

    finally:
        # Cleanup
        if work_dir.exists():
            shutil.rmtree(work_dir)


def update_metadata(build_matrix_json, archive_checksums, supported_versions_json, windows_matrix_json=None):
    """Update metadata files per os+architecture with build results."""
    build_matrix = json.loads(build_matrix_json)
    supported_versions = json.loads(supported_versions_json)
    windows_matrix = json.loads(windows_matrix_json) if windows_matrix_json else {'include': []}

    # Parse checksums: format is "version,os,arch,sha256,filename[,xdebug]"
    checksums_map = {}
    for line in archive_checksums.strip().split('\n'):
        if line:
            parts = line.split(',')
            if len(parts) < 5:
                raise ValueError(f"Invalid checksum format - expected version,os,arch,sha256,filename[,xdebug]: {line}")

            version, os_name, arch, sha256, filename = parts[:5]
            xdebug = parts[5] if len(parts) > 5 else None

            key = (os_name, arch)
            if key not in checksums_map:
                checksums_map[key] = {}
            checksums_map[key][version] = {
                'sha256': sha256,
                'filename': filename,
                'xdebug': xdebug
            }

    # Update metadata per os+architecture (Unix)
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

    # Update Windows metadata
    windows_key = (WINDOWS_OS, WINDOWS_ARCH)
    windows_metadata_file = get_metadata_file(WINDOWS_OS, WINDOWS_ARCH)
    windows_metadata = load_json(windows_metadata_file) if Path(windows_metadata_file).exists() else {}

    for build in windows_matrix.get('include', []):
        major_minor = build['php-version']
        full_version = build['full-version']

        if windows_key not in checksums_map or full_version not in checksums_map[windows_key]:
            print(f"Skipping {full_version} (windows) - no checksum (build may have failed)")
            continue

        release_date = build.get('releaseDate', '')
        checksum_data = checksums_map[windows_key][full_version]

        windows_metadata[major_minor] = {
            'latest': full_version,
            'releaseDate': release_date,
            'filename': checksum_data['filename'],
            'sha256': checksum_data['sha256'],
            'isEol': major_minor not in supported_versions,
            'xdebug': checksum_data.get('xdebug')
        }

        print(f"Updated {major_minor} (windows) -> {full_version}")

    # Update isEol for all existing Windows versions
    for version_key in windows_metadata:
        windows_metadata[version_key]['isEol'] = version_key not in supported_versions

    save_json(windows_metadata, windows_metadata_file)
    print(f"Updated {windows_metadata_file} for {len(windows_metadata)} PHP versions")


def cleanup_eol(eol_versions_json):
    """Remove EOL versions from metadata files for all os+architectures."""
    eol_versions = json.loads(eol_versions_json)

    # Cleanup Unix platforms
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

    # Cleanup Windows
    windows_metadata_file = get_metadata_file(WINDOWS_OS, WINDOWS_ARCH)
    if Path(windows_metadata_file).exists():
        windows_metadata = load_json(windows_metadata_file)
        removed_count = 0

        for version in eol_versions:
            if version in windows_metadata:
                del windows_metadata[version]
                print(f"Removed {version} from {windows_metadata_file}")
                removed_count += 1

        save_json(windows_metadata, windows_metadata_file)
        print(f"Removed {removed_count} EOL versions from {windows_metadata_file}")


def main():
    parser = argparse.ArgumentParser(description='PHP build manager')
    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    subparsers.add_parser('check-versions', help='Check PHP versions and generate build matrix')

    archive_parser = subparsers.add_parser('create-archive', help='Create tar.gz archive with CLI and FPM')
    archive_parser.add_argument('--php-version', required=True, help='PHP version')
    archive_parser.add_argument('--os', required=True, help='Operating system (darwin or linux)')
    archive_parser.add_argument('--arch', required=True, help='Architecture (arm64 or x86_64)')

    win_archive_parser = subparsers.add_parser('create-windows-archive', help='Download PHP Windows and create ZIP archive')
    win_archive_parser.add_argument('--php-version', required=True, help='PHP major.minor version (e.g., 8.4)')
    win_archive_parser.add_argument('--full-version', required=True, help='PHP full version (e.g., 8.4.3)')

    metadata_parser = subparsers.add_parser('update-metadata', help='Update metadata-php.json with build results')
    metadata_parser.add_argument('--build-matrix', required=True, help='JSON build matrix')
    metadata_parser.add_argument('--archive-checksums', required=True, help='Archive checksums (version,os,arch,sha256,filename[,xdebug] format)')
    metadata_parser.add_argument('--supported-versions', required=True, help='JSON array of supported PHP versions')
    metadata_parser.add_argument('--windows-matrix', required=False, default=None, help='JSON Windows build matrix')

    cleanup_parser = subparsers.add_parser('cleanup-eol', help='Remove EOL versions from metadata')
    cleanup_parser.add_argument('--eol-versions', required=True, help='JSON array of EOL versions')

    args = parser.parse_args()

    if args.command == 'check-versions':
        check_versions()
    elif args.command == 'create-archive':
        create_archive(args.php_version, args.os, args.arch)
    elif args.command == 'create-windows-archive':
        create_windows_archive(args.php_version, args.full_version)
    elif args.command == 'update-metadata':
        update_metadata(args.build_matrix, args.archive_checksums, args.supported_versions, args.windows_matrix)
    elif args.command == 'cleanup-eol':
        cleanup_eol(args.eol_versions)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
