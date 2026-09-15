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
    content = f"""#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
defaults=--no-defaults
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
    destination = Path(destination)
    destination.unlink(missing_ok=True)
    destination.write_text(content)
    destination.chmod(0o755)


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
