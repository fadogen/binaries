"""Plan lightweight application runtimes without starting native builders."""

from pathlib import Path
from urllib.request import urlopen

from native_packages.build import packager_digest as native_packager_digest
from native_packages.common import digest, file_digest
from native_packages.homebrew import FormulaAPI, version_key
from native_packages.planning import archive_name, fingerprint, identity

from .sources import SourceCache, composer_release, get_json, request, stable_release


def packager_digest():
    return digest(
        {
            "native": native_packager_digest(),
            "runtime": {name: file_digest(Path(__file__).parent / name) for name in ["build.py"]},
        }
    )


def composer_source(cache):
    release = composer_release(get_json("https://getcomposer.org/versions"))
    url = "https://getcomposer.org" + release["path"]
    with urlopen(request(url + ".sha256sum"), timeout=60) as response:
        checksum = response.read().decode().split()[0]
    return {"name": "composer", "version": release["version"], **cache.source(url, expected=checksum)}


def plan(config, cache, *, tools=None):
    cache, api = SourceCache(cache), FormulaAPI()
    tools = list(config["tools"] if tools is None else tools)
    if not tools or not set(tools).issubset(config["tools"]):
        raise ValueError("Unknown or empty runtime selection")
    packages = []
    for tool in tools:
        universal = tool in {"composer", "reverb"}
        targets = [{"os": "any", "arch": "any", "runner": "ubuntu-24.04"}] if universal else config["targets"]
        if tool == "sshpass":
            targets = [target for target in targets if target["os"] == "darwin"]
        for target in targets:
            package = {"service": tool, **target, "packager": packager_digest()}
            if tool in {"garage", "sshpass"}:
                formula = api.get(tool)
                package.update(
                    engine="homebrew",
                    formula=tool,
                    version=formula["versions"]["stable"],
                    components=api.closure(tool, target["tags"]),
                )
            elif tool == "composer":
                component = composer_source(cache)
                package.update(engine="phar", version=component["version"], components=[component])
            elif tool == "typesense":
                version = stable_release(
                    get_json("https://api.github.com/repos/typesense/typesense/releases/latest")
                )
                arch = "amd64" if target["arch"] == "x86_64" else "arm64"
                url = f"https://dl.typesense.org/releases/{version}/typesense-server-{version}-{target['os']}-{arch}.tar.gz"
                package.update(
                    engine="vendor", version=version, components=[{"name": tool, **cache.source(url)}]
                )
            else:
                repository = config["reverb_repository"]
                commit = get_json(f"https://api.github.com/repos/{repository}/commits/main")["sha"]
                lock = get_json(f"https://raw.githubusercontent.com/{repository}/{commit}/composer.lock")
                reverb = next(row for row in lock["packages"] if row["name"] == "laravel/reverb")
                url = f"https://api.github.com/repos/{repository}/tarball/{commit}"
                component = {"name": tool, "commit": commit, "lock": digest(lock), **cache.source(url)}
                package.update(
                    engine="composer",
                    version=reverb["version"].removeprefix("v"),
                    components=[component, composer_source(cache)],
                )
            version_key(package["version"])
            package["major"] = package["version"].split(".")[0]
            package["deps"] = fingerprint(package)
            package["id"] = identity(package)
            package["filename"] = archive_name(package, package["deps"])
            packages.append(package)
    return packages
