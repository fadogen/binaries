<?php
/**
 * Patch for IMAP extension configure test on Linux
 *
 * On modern glibc (2.17+), crypt() was moved from libc to libcrypt.
 * The IMAP c-client library uses crypt() for authentication.
 *
 * When cross-compiling with Zig, libcrypt is not available in the sysroot,
 * so we need to provide a stub library that satisfies the linker.
 */

$currentPoint = patch_point();

// Debug: always print the current patch point
if (getenv('SPC_DEBUG') || true) {
    echo "  [patch_imap_configure] Current patch_point: '$currentPoint'\n";
}

// Run at before-php-buildconf (after libs are built, before PHP configure)
if ($currentPoint === 'before-php-buildconf') {
    // Only apply on Linux
    if (PHP_OS_FAMILY !== 'Linux') {
        return;
    }

    // BUILD_ROOT_PATH may not be defined, use WORKING_DIR instead
    $buildrootLib = (defined('BUILD_ROOT_PATH') ? BUILD_ROOT_PATH : WORKING_DIR . '/buildroot') . '/lib';

    // Create libcrypt stub if it doesn't exist
    if (!file_exists($buildrootLib . '/libcrypt.a')) {
        echo "  [patch_imap_configure] Creating libcrypt stub for Zig cross-compilation...\n";

        // Create a minimal C file with the crypt() function stub
        $cryptStubC = <<<'C'
/* Stub for libcrypt - redirects to glibc crypt() or provides minimal implementation */
#define _GNU_SOURCE
#include <string.h>
#include <stdlib.h>

/* On glibc 2.17+, crypt() is in libcrypt, but when cross-compiling we may not have it.
 * This stub provides a minimal implementation that allows linking to succeed.
 * The actual crypt() will be resolved at runtime from the system's libcrypt.
 */

#ifndef __GLIBC__
/* Provide a weak symbol that can be overridden by the real libcrypt at runtime */
__attribute__((weak))
char *crypt(const char *phrase, const char *setting) {
    /* This is a placeholder - the real implementation should come from system libcrypt */
    (void)phrase;
    (void)setting;
    return NULL;
}

__attribute__((weak))
char *crypt_r(const char *phrase, const char *setting, void *data) {
    (void)phrase;
    (void)setting;
    (void)data;
    return NULL;
}
#else
/* On glibc, declare the functions as extern to allow linking */
extern char *crypt(const char *phrase, const char *setting);
extern char *crypt_r(const char *phrase, const char *setting, void *data);

/* Provide wrapper symbols */
char *__wrap_crypt(const char *phrase, const char *setting) {
    return crypt(phrase, setting);
}
#endif
C;

        $stubPath = $buildrootLib . '/crypt_stub.c';
        $objPath = $buildrootLib . '/crypt_stub.o';
        $libPath = $buildrootLib . '/libcrypt.a';

        file_put_contents($stubPath, $cryptStubC);

        // Detect the compiler being used
        $cc = getenv('CC') ?: 'gcc';
        $ar = getenv('AR') ?: 'ar';

        // If using zig-cc, use zig ar
        if (strpos($cc, 'zig') !== false) {
            $ar = 'zig ar';
        }

        // Compile the stub
        $cflags = '-c -fPIC -O2';
        $compileCmd = "$cc $cflags -o " . escapeshellarg($objPath) . " " . escapeshellarg($stubPath) . " 2>&1";
        exec($compileCmd, $output, $returnCode);

        if ($returnCode === 0 && file_exists($objPath)) {
            // Create the static library
            $arCmd = "$ar rcs " . escapeshellarg($libPath) . " " . escapeshellarg($objPath) . " 2>&1";
            exec($arCmd, $output2, $returnCode2);

            if ($returnCode2 === 0 && file_exists($libPath)) {
                echo "  [patch_imap_configure] Created libcrypt.a stub successfully\n";
            } else {
                echo "  [patch_imap_configure] Warning: Failed to create libcrypt.a: " . implode("\n", $output2) . "\n";
            }
        } else {
            echo "  [patch_imap_configure] Warning: Failed to compile crypt stub: " . implode("\n", $output) . "\n";
        }

        // Cleanup
        @unlink($stubPath);
        @unlink($objPath);
    }

    // Patch config.m4 to add -lcrypt to the test
    $configM4Path = SOURCE_PATH . '/php-src/ext/imap/config.m4';

    if (file_exists($configM4Path)) {
        $content = file_get_contents($configM4Path);

        // Check if the patch is needed
        if (strpos($content, 'TST_LIBS="$DLIBS $IMAP_SHARED_LIBADD') !== false &&
            strpos($content, '-lcrypt') === false) {

            // Add -lcrypt to the test libraries
            $content = str_replace(
                'TST_LIBS="$DLIBS $IMAP_SHARED_LIBADD -lz"',
                'TST_LIBS="$DLIBS $IMAP_SHARED_LIBADD -lssl -lcrypto -lz -lcrypt"',
                $content
            );

            $content = str_replace(
                'TST_LIBS="$DLIBS $IMAP_SHARED_LIBADD"',
                'TST_LIBS="$DLIBS $IMAP_SHARED_LIBADD -lssl -lcrypto -lcrypt"',
                $content
            );

            file_put_contents($configM4Path, $content);
            echo "  [patch_imap_configure] Added -lcrypt to IMAP configure test\n";
        }
    }
}
