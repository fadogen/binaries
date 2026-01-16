#!/bin/bash
# Patch for libsodium to fix GCC compilation on aarch64
# Based on commit 6702f69bef6044163acc7715e6ac7e430890ce78
# https://github.com/jedisct1/libsodium/commit/6702f69bef6044163acc7715e6ac7e430890ce78
set -e

BASE_DIR="$(pwd)"

apply_libsodium_patches() {
    local SODIUM_DIR="$1"
    local TARGET_FILE="$SODIUM_DIR/src/libsodium/crypto_ipcrypt/ipcrypt_armcrypto.c"

    if [ ! -f "$TARGET_FILE" ]; then
        echo "INFO: ipcrypt_armcrypto.c not found in $SODIUM_DIR"
        return 1
    fi

    # Check if already patched
    if [ -f "$SODIUM_DIR/.fadogen_patched" ]; then
        echo "INFO: libsodium already patched in $SODIUM_DIR"
        return 0
    fi

    echo "Patching libsodium for GCC aarch64 compatibility..."

    # Patch 1: Fix BYTESHL128 macro - use unsigned NEON intrinsics
    # Change: vextq_s8 -> vextq_u8, vdupq_n_s8 -> vdupq_n_u8, vreinterpretq_s8_u64 -> vreinterpretq_u8_u64
    if grep -q 'vextq_s8' "$TARGET_FILE" 2>/dev/null; then
        sed -i 's/vextq_s8(vdupq_n_s8(0), vreinterpretq_s8_u64(a)/vextq_u8(vdupq_n_u8(0), vreinterpretq_u8_u64(a)/g' "$TARGET_FILE"
        echo "  ✓ Patched BYTESHL128 macro"
    fi

    # Patch 2: Fix pfx_shift_left function - use explicit uint8x16_t types
    # Change BlockVec declarations to uint8x16_t for intermediate variables
    if grep -q 'const BlockVec shl' "$TARGET_FILE" 2>/dev/null; then
        sed -i 's/const BlockVec shl/const uint8x16_t shl/g' "$TARGET_FILE"
        sed -i 's/const BlockVec msb/const uint8x16_t msb/g' "$TARGET_FILE"
        sed -i 's/const BlockVec zero/const uint8x16_t zero/g' "$TARGET_FILE"
        sed -i 's/const BlockVec carries/const uint8x16_t carries/g' "$TARGET_FILE"
        echo "  ✓ Patched pfx_shift_left types"
    fi

    # Patch 3: Simplify carries assignment
    if grep -q 'vextq_u8(vreinterpretq_u8_u64(msb)' "$TARGET_FILE" 2>/dev/null; then
        sed -i 's/vextq_u8(vreinterpretq_u8_u64(msb), zero/vextq_u8(msb, zero/g' "$TARGET_FILE"
        echo "  ✓ Patched carries assignment"
    fi

    touch "$SODIUM_DIR/.fadogen_patched"
    echo "  ✓ libsodium patches applied successfully"
    return 0
}

echo "Searching for libsodium sources..."
PATCHED=false

# Search in downloads/ directory
if [ -d "$BASE_DIR/downloads" ]; then
    for dir in "$BASE_DIR/downloads/libsodium" "$BASE_DIR/downloads/libsodium-"*; do
        if [ -d "$dir" ] && [ -d "$dir/src/libsodium" ]; then
            echo "Found libsodium sources in $dir"
            if apply_libsodium_patches "$dir"; then
                PATCHED=true
            fi
        fi
    done
fi

# Also check source/ directory
if [ -d "$BASE_DIR/source/libsodium" ] && [ -d "$BASE_DIR/source/libsodium/src/libsodium" ]; then
    echo "Found libsodium sources in source/libsodium/"
    if apply_libsodium_patches "$BASE_DIR/source/libsodium"; then
        PATCHED=true
    fi
fi

if [ "$PATCHED" = false ]; then
    echo "INFO: libsodium source directory not found"
    echo "      This is expected if sources haven't been downloaded yet"
fi

echo ""
echo "✅ libsodium patch script completed"
echo ""

exit 0
