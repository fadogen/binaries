"""Resolve application paths at launch, without modifying the native engine."""

import os
import shlex
from pathlib import Path


def install_launcher(root, destination, native, service):
    if service not in {"mariadb", "mysql"}:
        raise ValueError(f"No SQL launcher for {service}")
    relative = shlex.quote(os.path.relpath(native, root))
    # Pre-registering RocksDB's internal directory avoids MariaDB MDEV-41029.
    options = "'--ignore-db-dir=#rocksdb'" if service == "mariadb" else "'--mysqlx=OFF'"
    content = f"""defaults=--no-defaults
case "${{1-}}" in
    --no-defaults|--defaults-file=*|--defaults-extra-file=*) defaults=$1; shift ;;
esac
data=
previous=
for argument do
    if [ "$previous" = --datadir ]; then data=$argument; fi
    case "$argument" in --datadir=*) data=${{argument#--datadir=}} ;; esac
    previous=$argument
done
if [ -n "$data" ]; then
    set -- "--socket=$data/{service}.sock" "--pid-file=$data/{service}.pid" "$@"
fi
exec "$root"/{relative} "$defaults" "--basedir=$root" "--plugin-dir=$root/lib/plugin" {options} "$@"
"""
    write_launcher(destination, content)


def write_launcher(destination, content):
    destination = Path(destination)
    destination.unlink(missing_ok=True)
    prelude = '#!/bin/sh\nset -eu\nroot=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)\n'
    destination.write_text(prelude + content)
    destination.chmod(0o755)


def install_postgres_launchers(root, keg, perl):
    core = list(perl.glob("lib/perl5/*/strict.pm"))
    architecture = [
        path for path in perl.glob("lib/perl5/*/*/Config.pm") if (path.parent / "Config_heavy.pl").is_file()
    ]
    if len(core) != 1 or len(architecture) != 1:
        raise ValueError("Cannot identify the bundled Perl standard library and architecture directory")
    paths = [architecture[0].parent, core[0].parent]
    expression = ":".join('"$root"/' + shlex.quote(os.path.relpath(path, root)) for path in paths)
    # pg_ctl starts the native postgres beside itself; both entry points must
    # supply the private Perl tree before the embedded interpreter initializes.
    for name in ["postgres", "pg_ctl"]:
        native = shlex.quote(os.path.relpath(keg / "bin" / name, root))
        write_launcher(root / "bin" / name, f'export PERL5LIB={expression}\nexec "$root"/{native} "$@"\n')


def patch_mariadb_installer(path):
    path = Path(path)
    content = path.read_text()
    for prefix in ["find_in_dirs", "cannot_find_file"]:
        old = f"{prefix} my_print_defaults $basedir/bin $basedir/extra"
        new = f'{prefix} my_print_defaults "$basedir/bin" "$basedir/extra"'
        if content.count(old) == 1:
            content = content.replace(old, new)
        elif content.count(new) != 1:
            raise ValueError("MariaDB installer changed; review its handling of paths with spaces")
    path.write_text(content)
