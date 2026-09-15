"""Resolve public formula metadata once, before any runner starts packaging."""

import json
import re
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


class Unavailable(ValueError):
    """An upstream formula or target bottle is not published."""


def version_key(version):
    if not re.fullmatch(r"\d+(?:\.\d+)*", version):
        raise Unavailable(f"Not a stable numeric release: {version}")
    return tuple(int(part) for part in version.split("."))


def runtime_dependencies(document, tag):
    variation = document.get("variations", {}).get(tag, {})
    dependencies = list(variation.get("dependencies", document.get("dependencies", [])))
    if tag.endswith("_linux"):
        for dependency in variation.get("uses_from_macos", document.get("uses_from_macos", [])):
            if isinstance(dependency, str):
                dependencies.append(dependency)
            else:
                dependencies.extend(name for name, kind in dependency.items() if kind != "build")
    return sorted(set(dependencies))


def select_bottle(document, tags):
    files = document.get("bottle", {}).get("stable", {}).get("files", {})
    for tag in [*tags, "all"]:
        if tag in files:
            return tag, files[tag]
    raise Unavailable(f"No bottle for {document['name']} on {', '.join(tags)}")


class FormulaAPI:
    def __init__(self, *, documents=None, base="https://formulae.brew.sh/api/formula"):
        self.documents = dict(documents or {})
        self.offline = documents is not None
        self.base = base.rstrip("/")

    def get(self, name):
        if not re.fullmatch(r"[a-z0-9][a-z0-9@+._-]*", name):
            raise ValueError(f"Invalid formula name: {name}")
        if name not in self.documents:
            if self.offline:
                raise Unavailable(f"Unknown formula: {name}")
            request = Request(
                f"{self.base}/{quote(name, safe='@')}.json", headers={"User-Agent": "Fadogen-Binaries"}
            )
            try:
                with urlopen(request, timeout=60) as response:
                    self.documents[name] = json.load(response)
            except HTTPError as error:
                if error.code == 404:
                    raise Unavailable(f"Unknown formula: {name}") from error
                raise
        return self.documents[name]

    def resolve(self, service, major):
        candidates = {service, f"{service}@{major}"}
        try:
            candidates.update(self.get(service).get("versioned_formulae", []))
        except Unavailable:
            pass
        matching = []
        for name in sorted(candidates):
            try:
                document = self.get(name)
                version = document["versions"]["stable"]
                if document.get("disabled") or version.split(".")[0] != major:
                    continue
                matching.append((version_key(version), document))
            except Unavailable:
                continue
        if not matching:
            raise Unavailable(f"No maintained formula serves {service}@{major}")
        return max(matching, key=lambda item: item[0])[1]

    def component(self, name, tags, *, role=None):
        document = self.get(name)
        tag, bottle = select_bottle(document, tags)
        dependencies = (
            []
            if role == "compiler-runtime"
            else runtime_dependencies(document, tags[0] if tag == "all" else tag)
        )
        return {
            "name": document["name"],
            "version": document["versions"]["stable"],
            "revision": document.get("revision", 0),
            "tag": tag,
            "url": bottle["url"],
            "sha256": bottle["sha256"],
            "license": document.get("license"),
            "source": document.get("urls", {}).get("stable", {}),
            "formula_commit": document.get("tap_git_head"),
            "formula_path": document.get("ruby_source_path"),
            "formula_checksum": document.get("ruby_source_checksum"),
            "dependencies": dependencies,
            "role": role,
        }

    def closure(self, formula, tags):
        ordered, visited, visiting = [], set(), set()
        linux = any(tag.endswith("_linux") for tag in tags)

        def visit(name):
            if name in visiting:
                raise ValueError(f"Dependency cycle at {name}")
            if name in visited:
                return
            visiting.add(name)
            component = self.component(
                name, tags, role="compiler-runtime" if name == "gcc" and linux else None
            )
            for dependency in component["dependencies"]:
                visit(dependency)
            ordered.append(component)
            visiting.remove(name)
            visited.add(name)

        visit(formula)
        if linux:
            # Homebrew implicitly supplies GCC runtimes on Linux. Keep the shared
            # libraries, not the compiler executable or its toolchain dependencies.
            visit("gcc")
        return ordered
