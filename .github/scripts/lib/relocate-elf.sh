#!/bin/bash
# Relocate ELF binaries (executables, shared libraries)
# Linux equivalent of relocate.sh for macOS Mach-O files
#
# Usage: relocate_elf_files <prefix>
#   prefix: The installation directory containing bin/ and lib/

set -e

relocate_elf_files() {
    local PREFIX="$1"

    # Check if patchelf is available
    if ! command -v patchelf >/dev/null 2>&1; then
        echo "  WARNING: patchelf not found, skipping ELF relocation"
        return 0
    fi

    echo "→ Relocating ELF files..."

    local count=0

    # Fix executables in bin/ - they need to find libs in ../lib/
    if [[ -d "${PREFIX}/bin" ]]; then
        while IFS= read -r -d '' file; do
            # Skip symlinks
            [[ -L "$file" ]] && continue

            # Check if it's an ELF executable
            if file "$file" | grep -q "ELF.*executable"; then
                patchelf --set-rpath '$ORIGIN/../lib' "$file" 2>/dev/null || true
                echo "    ✓ $(basename "$file") (bin)"
                ((count++)) || true
            fi
        done < <(find "${PREFIX}/bin" -type f -print0 2>/dev/null)
    fi

    # Fix shared libraries in lib/ - they need to find other libs in same directory
    if [[ -d "${PREFIX}/lib" ]]; then
        while IFS= read -r -d '' file; do
            # Skip symlinks
            [[ -L "$file" ]] && continue

            # Check if it's an ELF shared library
            if file "$file" | grep -q "ELF.*shared object"; then
                patchelf --set-rpath '$ORIGIN' "$file" 2>/dev/null || true
                echo "    ✓ $(basename "$file") (lib)"
                ((count++)) || true
            fi
        done < <(find "${PREFIX}/lib" -maxdepth 1 -type f -name "*.so*" -print0 2>/dev/null)
    fi

    echo "✓ Relocated ${count} ELF files"
}
