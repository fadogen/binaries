"""Keep runtime files in distinct kegs and expose Fadogen's directory contract."""

import os
import re
from pathlib import Path

PREFIX = r"(?:@@HOMEBREW_PREFIX@@|/opt/homebrew|/usr/local|/home/linuxbrew/\.linuxbrew)"
CELLAR = rf"(?:@@HOMEBREW_CELLAR@@|{PREFIX}/Cellar)"


def runtime_files(path, component=None):
    path = Path(path)
    if re.match(r"^(?:LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE)(?:[._-]|$)", path.name, re.IGNORECASE):
        return True
    if component and component.get("role") == "compiler-runtime":
        return bool(re.fullmatch(r"lib(?:atomic|gcc_s|stdc\+\+|gomp)\.so(?:\.[0-9]+)*", path.name))
    if path.name == "rcmysql":
        return False
    excluded = {
        ".brew",
        "include",
        "doc",
        "docs",
        "man",
        "mysql-test",
        "mariadb-test",
        "test",
        "tests",
        "pkgconfig",
        "cmake",
    }
    return not excluded.intersection(path.parts) and path.suffix not in {".a", ".la", ".o", ".pc"}


def trim_keg(keg):
    for path in sorted(keg.rglob("*"), reverse=True):
        if path.is_dir() and not path.is_symlink():
            if not any(path.iterdir()):
                path.rmdir()
        elif not runtime_files(path.relative_to(keg)):
            path.unlink()


def dependency_target(reference, locations):
    matched = re.match(rf"^{PREFIX}/opt/([^/]+)/(.*)$", reference)
    if matched:
        name, suffix = matched.groups()
    else:
        matched = re.match(rf"^{CELLAR}/([^/]+)/[^/]+/(.*)$", reference)
        if matched:
            name, suffix = matched.groups()
        else:
            matched = re.match(rf"^{PREFIX}/lib/(postgresql@[^/]+)/(.*)$", reference)
            if not matched:
                if "@@HOMEBREW" in reference or re.match(rf"^{PREFIX}/", reference):
                    raise ValueError(f"Unresolved Homebrew dependency: {reference}")
                return None
            name, suffix = matched.groups()
            if name not in locations:
                raise ValueError(f"Missing dependency bottle: {reference}")
            candidates = [
                locations[name] / folder / suffix for folder in [f"lib/{name}", "lib/postgresql", "lib"]
            ]
            present = [path for path in candidates if path.exists()]
            if len(present) != 1:
                raise ValueError(f"Missing or ambiguous PostgreSQL runtime file: {reference}")
            return present[0]
    if name not in locations:
        raise ValueError(f"Missing dependency bottle: {reference}")
    destination = locations[name] / suffix
    if not destination.exists():
        raise ValueError(f"Missing runtime file: {reference}")
    return destination


def relative_link(destination, source):
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.symlink_to(os.path.relpath(source, destination.parent))


def expose_service(root, service, formula, keg):
    (root / "bin").mkdir()
    for path in sorted((keg / "bin").iterdir()):
        relative_link(root / "bin" / path.name, path)
    if service == "postgresql":
        for folder in ["lib", "share"]:
            source = keg / folder / "postgresql"
            if not source.is_dir():
                source = keg / folder / formula
            if not source.is_dir():
                raise ValueError(f"Missing PostgreSQL {folder} runtime directory")
            relative_link(root / folder / formula, source)
    else:
        for folder in ["lib", "share", "etc"]:
            if (keg / folder).exists():
                relative_link(root / folder, keg / folder)
    if service == "mariadb":
        script = keg / "bin/mariadb-install-db"
        if not script.is_file():
            raise ValueError("MariaDB bottle lacks mariadb-install-db")
        relative_link(root / "scripts/mariadb-install-db", script)
    if service == "redis":
        for module in (keg / "lib/redis/modules").glob("*.so"):
            module.chmod(module.stat().st_mode | 0o111)


def repair_links(root, locations):
    for path in root.rglob("*"):
        if not path.is_symlink():
            continue
        original = os.readlink(path)
        target = dependency_target(original, locations)
        if target is not None:
            path.unlink()
            relative_link(path, target)
        elif original.startswith("/"):
            raise ValueError(f"Absolute symlink remains in package: {path}: {original}")
        elif not path.resolve().is_relative_to(root):
            raise ValueError(f"Symlink leaves package: {path}: {original}")
