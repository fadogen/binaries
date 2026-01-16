#!/bin/bash
# Patch for IMAP c-client library to fix compilation errors with modern GCC
# Based on patches from OpenEmbedded meta-oe layer
# https://git.openembedded.org/meta-openembedded/tree/meta-oe/recipes-devtools/uw-imap/uw-imap
set -e

BASE_DIR="$(pwd)"

# Function to apply IMAP source patches
apply_imap_source_patches() {
    local IMAP_DIR="$1"

    if [ ! -d "$IMAP_DIR" ]; then
        return 1
    fi

    # Check if already patched
    if [ -f "$IMAP_DIR/.fadogen_patched" ]; then
        echo "INFO: IMAP sources already patched in $IMAP_DIR"
        return 0
    fi

    echo "Patching IMAP sources in $IMAP_DIR for modern GCC compatibility..."

    cd "$IMAP_DIR"

    # Patch 1: Define prototype for safe_flock
    # Source: OpenEmbedded 0001-Define-prototype-for-safe_flock.patch
    echo "Applying safe_flock prototype declarations..."

    if [ -f "src/osdep/unix/env_unix.c" ] && ! grep -q "extern int safe_flock" "src/osdep/unix/env_unix.c"; then
        sed -i '/#define S_IXOTH/a\extern int safe_flock (int fd,int op);' "src/osdep/unix/env_unix.c"
        echo "  ✓ Patched src/osdep/unix/env_unix.c"
    fi

    if [ -f "src/osdep/unix/mbx.c" ] && ! grep -q "extern int safe_flock" "src/osdep/unix/mbx.c"; then
        sed -i '/#include "misc.h"/a\#include <utime.h>\nextern int safe_flock (int fd,int op);' "src/osdep/unix/mbx.c"
        echo "  ✓ Patched src/osdep/unix/mbx.c"
    fi

    if [ -f "src/osdep/unix/os_lnx.h" ] && ! grep -q "extern int safe_flock" "src/osdep/unix/os_lnx.h"; then
        sed -i '/#define flock safe_flock/i\extern int safe_flock (int fd,int op);' "src/osdep/unix/os_lnx.h"
        echo "  ✓ Patched src/osdep/unix/os_lnx.h"
    fi

    if [ -f "src/osdep/unix/os_slx.h" ] && ! grep -q "extern int safe_flock" "src/osdep/unix/os_slx.h"; then
        sed -i '/#define flock safe_flock/i\#include <utime.h>\nextern int safe_flock (int fd,int op);' "src/osdep/unix/os_slx.h"
        echo "  ✓ Patched src/osdep/unix/os_slx.h"
    fi

    if [ -f "src/osdep/unix/unix.c" ] && ! grep -q "extern int safe_flock" "src/osdep/unix/unix.c"; then
        sed -i '/#include "misc.h"/a\#include <utime.h>\nextern int safe_flock (int fd,int op);' "src/osdep/unix/unix.c"
        echo "  ✓ Patched src/osdep/unix/unix.c"
    fi

    # Patch 2: Fix incompatible function pointer types for scandir
    # Source: OpenEmbedded 0001-Fix-Wincompatible-function-pointer-types.patch
    echo "Fixing scandir function pointer signatures..."

    # news.c
    if [ -f "src/osdep/unix/news.c" ]; then
        sed -i 's/int news_select (struct direct \*name)/int news_select (const struct direct *name)/g' src/osdep/unix/news.c
        sed -i 's/int news_numsort (const void \*d1,const void \*d2)/int news_numsort (const struct dirent **d1, const struct dirent **d2)/g' src/osdep/unix/news.c
        sed -i 's/return (atoi (((struct direct \*) d1)->d_name) - atoi (((struct direct \*) d2)->d_name));/return (atoi ((*d1)->d_name) - atoi ((*d2)->d_name));/' src/osdep/unix/news.c
        echo "  ✓ Patched src/osdep/unix/news.c"
    fi

    # mh.c
    if [ -f "src/osdep/unix/mh.c" ]; then
        sed -i 's/int mh_select (struct direct \*name)/int mh_select (const struct direct *name)/g' src/osdep/unix/mh.c
        sed -i 's/int mh_numsort (const void \*d1,const void \*d2)/int mh_numsort (const struct dirent **d1, const struct dirent **d2)/g' src/osdep/unix/mh.c
        sed -i 's/return (atoi (((struct direct \*) d1)->d_name) - atoi (((struct direct \*) d2)->d_name));/return (atoi ((*d1)->d_name) - atoi ((*d2)->d_name));/' src/osdep/unix/mh.c
        echo "  ✓ Patched src/osdep/unix/mh.c"
    fi

    # mx.c
    if [ -f "src/osdep/unix/mx.c" ]; then
        sed -i 's/int mx_select (struct direct \*name)/int mx_select (const struct direct *name)/g' src/osdep/unix/mx.c
        sed -i 's/int mx_numsort (const void \*d1,const void \*d2)/int mx_numsort (const struct dirent **d1, const struct dirent **d2)/g' src/osdep/unix/mx.c
        sed -i 's/return (atoi (((struct direct \*) d1)->d_name) - atoi (((struct direct \*) d2)->d_name));/return (atoi ((*d1)->d_name) - atoi ((*d2)->d_name));/' src/osdep/unix/mx.c
        echo "  ✓ Patched src/osdep/unix/mx.c"
    fi

    # mix.c
    if [ -f "src/osdep/unix/mix.c" ]; then
        sed -i 's/int mix_select (struct direct \*name)/int mix_select (const struct dirent *name)/g' src/osdep/unix/mix.c
        sed -i 's/int mix_rselect (struct direct \*name)/int mix_rselect (const struct dirent *name)/g' src/osdep/unix/mix.c
        sed -i 's/int mix_msgfsort (const void \*d1,const void \*d2)/int mix_msgfsort (const struct dirent **d1, const struct dirent **d2)/g' src/osdep/unix/mix.c
        sed -i 's/return (atoi (((struct direct \*) d1)->d_name) - atoi (((struct direct \*) d2)->d_name));/return (atoi ((*d1)->d_name) - atoi ((*d2)->d_name));/' src/osdep/unix/mix.c
        echo "  ✓ Patched src/osdep/unix/mix.c"
    fi

    # Patch 3: Fix deprecated gets() in mtest.c
    echo "Fixing deprecated gets() function..."
    if [ -f "src/mtest/mtest.c" ] && grep -q '\bgets\s*(' src/mtest/mtest.c 2>/dev/null; then
        sed -i '1i\/* Safe replacement for deprecated gets() function *\/\n#define gets(s) (fgets(s, 1024, stdin) ? (s[strcspn(s, "\\n")] = 0, s) : NULL)\n' src/mtest/mtest.c
        echo "  ✓ Patched src/mtest/mtest.c"
    fi

    # Patch 4: Disable building mtest and other bundled tools
    echo "Disabling bundled tools build..."
    if [ -f "Makefile" ] && grep -q '$(CD) mtest;$(MAKE)' Makefile; then
        sed -i '/^bundled:/,/^$/s/\t\$(CD) mtest;\$(MAKE)/#\t\$(CD) mtest;\$(MAKE) # Disabled/' Makefile
        sed -i '/^bundled:/,/^$/s/\t\$(CD) ipopd;\$(MAKE)/#\t\$(CD) ipopd;\$(MAKE) # Disabled/' Makefile
        sed -i '/^bundled:/,/^$/s/\t\$(CD) imapd;\$(MAKE)/#\t\$(CD) imapd;\$(MAKE) # Disabled/' Makefile
        sed -i '/^bundled:/,/^$/s/\t\$(CD) mailutil;\$(MAKE)/#\t\$(CD) mailutil;\$(MAKE) # Disabled/' Makefile
        sed -i '/^bundled:/,/^$/s/\t\$(CD) mlock;\$(MAKE)/#\t\$(CD) mlock;\$(MAKE) # Disabled/' Makefile
        sed -i '/^bundled:/,/^$/s/\t\$(CD) dmail;\$(MAKE)/#\t\$(CD) dmail;\$(MAKE) # Disabled/' Makefile
        echo "  ✓ Disabled mtest, ipopd, imapd, mailutil, mlock, dmail"
    fi

    # Mark as patched
    touch "$IMAP_DIR/.fadogen_patched"

    echo "  ✓ IMAP source patches applied successfully in $IMAP_DIR"
    cd "$BASE_DIR"
    return 0
}

# Try to find and patch IMAP sources
# static-php-cli may store sources in various locations depending on the source type
PATCHED=false

echo "Searching for IMAP sources..."

# Search in downloads/ directory for any imap-related directories
if [ -d "$BASE_DIR/downloads" ]; then
    # Look for directories containing IMAP sources (have src/osdep/unix structure)
    for dir in "$BASE_DIR/downloads/imap" "$BASE_DIR/downloads/imap-"* "$BASE_DIR/downloads/"*imap*; do
        if [ -d "$dir" ] && [ -d "$dir/src/osdep/unix" ]; then
            echo "Found IMAP sources in $dir"
            if apply_imap_source_patches "$dir"; then
                PATCHED=true
            fi
        fi
    done
fi

# Also check source/ directory (in case extraction already happened)
if [ -d "$BASE_DIR/source/imap" ] && [ -d "$BASE_DIR/source/imap/src/osdep/unix" ]; then
    echo "Found IMAP sources in source/imap/"
    if apply_imap_source_patches "$BASE_DIR/source/imap"; then
        PATCHED=true
    fi
fi

if [ "$PATCHED" = false ]; then
    echo "INFO: IMAP source directory not found in downloads/ or source/"
    echo "      Listing downloads/ contents for debugging:"
    ls -la "$BASE_DIR/downloads/" 2>/dev/null || echo "      downloads/ directory not found"
    echo ""
    echo "      This is expected if sources haven't been downloaded yet"
fi

# Patch 5: Add required libraries to PHP IMAP configure test
# This is specific to static-php-cli and ensures PHP configure test links correctly
echo "Checking PHP ext/imap/config.m4..."
PHP_IMAP_CONFIG="$BASE_DIR/source/php-src/ext/imap/config.m4"
if [ -f "$PHP_IMAP_CONFIG" ] && grep -q 'TST_LIBS="$DLIBS $IMAP_SHARED_LIBADD -lz"' "$PHP_IMAP_CONFIG"; then
    sed -i 's|TST_LIBS="$DLIBS $IMAP_SHARED_LIBADD -lz"|TST_LIBS="$DLIBS $IMAP_SHARED_LIBADD -lssl -lcrypto -lz -lcrypt"|' "$PHP_IMAP_CONFIG"
    echo "  ✓ Added -lssl -lcrypto -lcrypt to PHP configure test"
fi

# Patch 6: Create libcrypt compatibility layer for newer glibc symbols
# This is specific to static builds on systems with glibc 2.38+ targeting older glibc
# Provides __isoc23_strtoul and arc4random_buf symbols
echo "Checking libcrypt compatibility layer..."
BUILDROOT_LIB="$BASE_DIR/buildroot/lib"
if [ -d "$BUILDROOT_LIB" ]; then
    COMPAT_FILE="$BUILDROOT_LIB/libcrypt_compat.c"

    # Create compatibility source file
    cat > "$COMPAT_FILE" << 'EOF'
/* Compatibility layer for libcrypt.a with older glibc
 * Provides missing symbols when building on glibc 2.38+ for older targets
 */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/random.h>

/* ISO C23 strtoul - redirect to standard strtoul */
unsigned long __isoc23_strtoul(const char *nptr, char **endptr, int base) {
    return strtoul(nptr, endptr, base);
}

/* arc4random_buf - use getrandom() syscall with /dev/urandom fallback */
void arc4random_buf(void *buf, size_t nbytes) {
    if (getrandom(buf, nbytes, 0) < 0) {
        /* Fallback to reading from /dev/urandom if getrandom fails */
        FILE *f = fopen("/dev/urandom", "rb");
        if (f) {
            fread(buf, 1, nbytes, f);
            fclose(f);
        }
    }
}
EOF

    # Compile compatibility layer
    CC="${CC:-gcc}"
    $CC -c -fPIC "$COMPAT_FILE" -o "$BUILDROOT_LIB/libcrypt_compat.o"
    ar rcs "$BUILDROOT_LIB/libcrypt_compat.a" "$BUILDROOT_LIB/libcrypt_compat.o"

    # Copy system libcrypt.a and merge with compatibility layer
    if [ -f "/usr/lib/aarch64-linux-gnu/libcrypt.a" ]; then
        cp /usr/lib/aarch64-linux-gnu/libcrypt.a "$BUILDROOT_LIB/libcrypt.a"
    elif [ -f "/usr/lib/x86_64-linux-gnu/libcrypt.a" ]; then
        cp /usr/lib/x86_64-linux-gnu/libcrypt.a "$BUILDROOT_LIB/libcrypt.a"
    fi

    # Merge compatibility symbols into libcrypt.a
    if [ -f "$BUILDROOT_LIB/libcrypt.a" ]; then
        ar x "$BUILDROOT_LIB/libcrypt_compat.a" libcrypt_compat.o
        ar r "$BUILDROOT_LIB/libcrypt.a" libcrypt_compat.o
        rm -f libcrypt_compat.o "$BUILDROOT_LIB/libcrypt_compat.o" "$BUILDROOT_LIB/libcrypt_compat.a" "$COMPAT_FILE"
        echo "  ✓ Created libcrypt.a with compatibility layer"
    fi
fi

echo ""
echo "✅ IMAP patch script completed"
echo ""

exit 0
