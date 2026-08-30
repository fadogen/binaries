<?php
/**
 * Patch libsodium for GCC aarch64 NEON compatibility
 * Based on commit 6702f69bef6044163acc7715e6ac7e430890ce78
 * https://github.com/jedisct1/libsodium/commit/6702f69bef6044163acc7715e6ac7e430890ce78
 *
 * This patch is only needed on Linux with GCC. macOS uses Clang which doesn't
 * have this NEON type incompatibility issue.
 */

// Only apply on Linux (GCC has the NEON issue, Clang on macOS doesn't)
if (PHP_OS_FAMILY !== 'Linux') {
    return;
}

$target = SOURCE_PATH . '/libsodium/src/libsodium/crypto_ipcrypt/ipcrypt_armcrypto.c';
$marker = SOURCE_PATH . '/libsodium/.fadogen_patched';

// Skip if file doesn't exist yet (not extracted) or already patched
if (!file_exists($target) || file_exists($marker)) {
    return;
}

logger()->info('Patching libsodium for GCC aarch64 NEON compatibility...');

// Patch 1: Fix BYTESHL128 macro - use unsigned NEON intrinsics
\SPC\store\FileSystem::replaceFileStr(
    $target,
    'vextq_s8(vdupq_n_s8(0), vreinterpretq_s8_u64(a)',
    'vextq_u8(vdupq_n_u8(0), vreinterpretq_u8_u64(a)'
);

// Patch 2: Fix pfx_shift_left function - use explicit uint8x16_t types
\SPC\store\FileSystem::replaceFileStr($target, 'const BlockVec shl', 'const uint8x16_t shl');
\SPC\store\FileSystem::replaceFileStr($target, 'const BlockVec msb', 'const uint8x16_t msb');
\SPC\store\FileSystem::replaceFileStr($target, 'const BlockVec zero', 'const uint8x16_t zero');
\SPC\store\FileSystem::replaceFileStr($target, 'const BlockVec carries', 'const uint8x16_t carries');

// Patch 3: Simplify carries assignment
\SPC\store\FileSystem::replaceFileStr(
    $target,
    'vextq_u8(vreinterpretq_u8_u64(msb), zero',
    'vextq_u8(msb, zero'
);

// Mark as patched to avoid re-patching
file_put_contents($marker, date('c'));
logger()->info('libsodium patches applied successfully');
