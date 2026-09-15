"""Adapt verified receipts to the catalogues consumed by Fadogen."""

from copy import deepcopy

from native_packages.planning import identity, validate_receipt

from .php import validate_php_receipt


def catalogue_name(package):
    name = package["service"]
    if package["os"] != "any":
        name += f"-{package['os']}-{package['arch']}"
    return f"metadata-{name}.json"


def record_path(package):
    if package["service"] == "php":
        return [package["major"]]
    if package["service"] == "reverb":
        return ["reverb"]
    return []


def previous_record(package, catalogues):
    record = catalogues.get(catalogue_name(package), {})
    for key in record_path(package):
        record = record.get(key, {})
    if not isinstance(record, dict):
        raise ValueError(f"Invalid catalogue record for {identity(package)}")
    return record


def selected_packages(packages, catalogues, *, force=False):
    selected = []
    for package in packages:
        previous = previous_record(package, catalogues)
        field = "version" if package["service"] == "sshpass" else "latest"
        if force or previous.get(field) != package["version"] or previous.get("deps") != package["deps"]:
            selected.append(package)
    return selected


def merge_catalogues(catalogues, receipts, packages):
    expected = {identity(package): package for package in packages}
    if len(expected) != len(packages):
        raise ValueError("Duplicate package in the plan")
    result, seen = deepcopy(catalogues), set()
    # The complete plan already contains PHP.net's validated support policy.
    # Failed builds retain their published record; retired branches do not.
    for name in {catalogue_name(row) for row in packages if row["service"] == "php"}:
        supported = {row["major"] for row in packages if catalogue_name(row) == name}
        result[name] = {major: row for major, row in result.get(name, {}).items() if major in supported}
    for receipt in receipts:
        key = identity(receipt)
        if key not in expected or key in seen:
            raise ValueError(f"Unexpected or duplicate receipt: {key}")
        package = expected[key]
        if package["service"] == "php":
            validate_php_receipt(package, receipt)
        else:
            validate_receipt(package, receipt)
        name = catalogue_name(package)
        field = "version" if package["service"] == "sshpass" else "latest"
        record = {field: receipt["version"], **{key: receipt[key] for key in ["sha256", "filename", "deps"]}}
        if package["service"] == "php":
            record.update(releaseDate=package["releaseDate"], isEol=False)
            for extension in ["xdebug", "redis"]:
                if extension in package:
                    record[extension] = package[extension]
        path = record_path(package)
        if path:
            parent = result.setdefault(name, {})
            for key in path[:-1]:
                parent = parent.setdefault(key, {})
            parent[path[-1]] = record
        else:
            result[name] = record
        seen.add(identity(receipt))
    return result
