# Fadogen Binaries

Native runtimes downloaded by [Fadogen](https://github.com/fouteox/tauri-fadogen).
Database and cache engines are **repackaged from Homebrew bottles**, together with
their runtime dependencies. Users do not install Homebrew. PHP continues to use
static-php-cli. Composer, Garage, sshpass, Typesense and Reverb share one runtime
packager and publisher; PHP reuses its verification and publication workflow.

## Service catalogue

| Service | Major lines | macOS ARM64 | Linux ARM64 / x86_64 | Windows x86_64 |
| --- | --- | --- | --- | --- |
| MariaDB | 10, 11, 12 | Homebrew | Homebrew | MariaDB archive |
| MySQL | 8, 9 | Homebrew | Homebrew | Oracle archive |
| PostgreSQL | 14–18 | Homebrew | Homebrew | EnterpriseDB archive |
| Redis | 8 | Homebrew | Homebrew | Existing community source |
| Valkey | 9 | Homebrew | Homebrew | Unavailable |

`.github/config/services.json` is the catalogue. The resolver picks the highest
published formula within each configured major: MySQL 8 can resolve to `mysql@8.4`
even when the unversioned formula has moved to a different major. Missing bottles
are reported as unavailable; they never trigger a source compilation or remove a
previously published platform entry.

The service matrix drops Intel Macs. Fadogen's intended macOS baseline is 27;
packaging currently uses the standard ARM64 macOS 26 runner and selects an older
compatible bottle where available. Linux qualification uses Ubuntu 24.04 on both
architectures. PHP also uses a Windows x64 runner to execute its CLI and CGI.

## Other runtimes

| Runtime | Source | Qualification |
| --- | --- | --- |
| Composer | Official PHAR and SHA-256 | Version, project validation, offline installation |
| Garage | Homebrew bottles with runtime dependencies | Single-node S3 upload/download, restart, persisted object |
| Typesense | Official macOS/Linux archives | Health, version, collection indexing, search after restart |
| sshpass | Homebrew macOS ARM64 bottle | Version and controlling-terminal password exchange |
| Reverb | Committed source and Composer lock from `fadogen/laravel-reverb` | WebSocket upgrade, subscription, signed event broadcast, restart |
| PHP | Pinned stable static-php-cli on Unix; official NTS x64 ZIP on Windows | CLI and FPM/CGI requests, extensions, SQLite persistence, Intl, Sodium, GD, Xdebug |

`.github/config/runtimes.json` selects utilities; `.github/config/php.json` selects
maintained PHP branches, extensions and the exact SPC release with upstream
checksums. The utility resolver hashes upstream bytes even when the version stays
unchanged. Homebrew runtime dependency bottles participate in the same fingerprint.
The Composer PHAR used to install Reverb is also pinned in its input plan.

Reverb's Laravel application and dependency updates remain in its own repository.
Dependabot proposes committed lockfile updates there. Binaries packages only the
resolved main commit, runs `composer install` and the production dependency audit,
and refuses a changed lockfile. No generated app key, initialized database, private
environment or build-time configuration cache is published. The checked-in public
local defaults remain available for Fadogen's existing launch contract. Reverb and
Composer use Fadogen's PHP interpreter; they do not embed another PHP installation.

The PHP workflow checks daily rather than every six hours. PHP.net's supported
branches bound the configured catalogue. Each native target resolves the required
sources and available prebuilt libraries, then hashes those inputs before deciding
whether compilation is necessary. This still starts native runners and downloads
sources on an unchanged check; it avoids repeating compilation, not all runner time.
Optional sources that are not built are excluded. Full PHP versions and their
official source checksums are frozen; no mutable nightly SPC executable is used.
Windows planning pins PHP, Xdebug and Redis bytes, and fails if a required extension
is unavailable. SPC or extension-policy upgrades are explicit configuration changes.

## Build and verify locally

The scripts use only the Python standard library. Install uv at the version pinned
in `pyproject.toml`, then run `uv sync --locked --managed-python` to install the
Python version pinned in `.python-version` and the tools in `uv.lock`. Run on the target architecture:
macOS needs `otool`, `install_name_tool` and `codesign`; Linux needs `patchelf`,
`readelf` and `ldd`. Functional tests also use the system `openssl`. Homebrew itself
is not invoked or installed by the packager.

```sh
uv run --locked --no-dev python .github/scripts/package-services.py plan \
  --services postgresql --majors 18 --os darwin --arch arm64 \
  --output package-plan.json
uv run --locked --no-dev python .github/scripts/package-services.py build \
  --plan package-plan.json --id postgresql-18-darwin-arm64
uv run --locked --no-dev python .github/scripts/package-services.py verify \
  --plan package-plan.json --id postgresql-18-darwin-arm64
```

`dist/` contains the final archive, its JSON receipt and qualification evidence.
The default macOS signature is ad hoc. Production requires a Developer ID identity
and a temporary keychain; every Mach-O file is signed and verified before packaging.
Never install or test over an existing database's data directory.

The runtime keeps private `Cellar/<formula>/<version>` directories to avoid library
name collisions, with relative `bin`, `lib`, `share` and `opt` links. Fadogen keeps
its existing archive extraction and launch contract. SQL launchers resolve the
package location, private sockets and plugin paths; they preserve caller overrides.
MariaDB's installer has a guarded quoting correction for paths containing spaces.
Build-only headers, static archives, manuals and tests are removed; license files
and extension resources are retained. `PROVENANCE.json` records every input URL,
checksum, formula revision/source and relocation performed.

## Publication

The scheduled job checks for changes daily; it does not rebuild identical inputs.
A frozen JSON plan is shared by packaging, verification and publication. Dependency
bottle checksums and packager changes affect the fingerprint; unrelated Homebrew
tap commits do not. Metadata is never recomputed from a different checkout or
restated without building the corresponding archive.

Each successful job tests the **final compressed archive** after extraction and
movement to a path with spaces, then attests and uploads those exact bytes. Archive
names include the full SHA-256. Only uploaded-success receipts reach the metadata
job, which rereads the current metadata and merges those entries. Supported entries
whose replacement failed keep their published package. Production runs are serialized; storage access
errors fail the job instead of replacing metadata with an empty object.

The publisher reconciles every catalogue with the configured services, majors and
platforms, including runs with no rebuild or an OS filter. After publishing and
rereading the current catalogues, it deletes retired platform catalogues and
recognized service archives that are no longer referenced. The application is not
released; no compatibility catalogue or historical archive retention is maintained.
An unsuccessful publication or a different remote snapshot prevents cleanup.
Unrelated R2 objects and archives belonging to PHP or independent utilities are
outside its scope. `update-metadata` provides a local preview without deleting objects.
GitHub stores small plans, receipts and test evidence for seven days, not the
runtime archives or a permanent multi-gigabyte cache.

Pull requests run Unix packaging and runtime qualification without signing secrets,
R2 writes or attestations. Windows keeps its existing vendor downloader and adds ZIP
integrity, required executable and PE x64 checks. **These are structural checks, not
Windows execution tests.** A missing release, source-only ZIP or incorrect layout
fails instead of being published as a working runtime. The Redis community source
is not equivalent to an official cross-platform Redis release.

## Python environment

All Python workflow steps use the shared
`.github/actions/setup-uv` action. Its Astral action revision is pinned, uv reads its
required version from `pyproject.toml`, and Python reads `.python-version`.
`uv sync --locked` rejects a missing or stale lockfile. Commands use `uv run --locked`;
packaging excludes development dependencies, while the test job installs the locked
Ruff release. Only the test job enables the small dependency cache. No global Python
environment is modified. PHP source builds may install compiler prerequisites on
disposable CI runners; local builds do not request SPC's system auto-fixes.
Python or tool upgrades are explicit repository changes,
separate from the daily refresh of Homebrew runtime components.

## Tests

```sh
uv run --locked python -m unittest discover -s tests/python -v
uv run --locked ruff check .github/scripts/package-*.py .github/scripts/native_packages .github/scripts/runtime_packages tests/python
uv run --locked ruff format --check .github/scripts/package-*.py .github/scripts/native_packages .github/scripts/runtime_packages tests/python
```

The offline regression suite covers dependency resolution, immutable inputs,
partial publication, checksums, archive extraction, relocation, SQL launcher
arguments and storage failures. Runtime qualification exercises initialization,
TLS certificate verification (including rejection of an unrelated CA), SQL
backup/restore, extensions, two independent instances and persistence after restart.
PostgreSQL tests Perl on both Unix platforms and Tcl on macOS, matching Homebrew.
Linux PostgreSQL launchers also resolve the bundled Perl module directories.
Redis tests JSON, Bloom, Search and TimeSeries. MariaDB tests Mroonga full-text search with TokenMecab and RocksDB
where provided by the formula. MySQL uses classic SQL and disables its default
shared X Plugin socket unless the caller overrides it.

On macOS, sandbox-exec denies access to Homebrew and installed Fadogen runtimes.
On Linux, all ELF bindings are checked against the package and an explicit system
library allowlist; CI additionally hides Linuxbrew before execution. Linux still
bundles GCC's shared C++/atomic runtimes and requires the distribution's glibc and loader: this is not a promise
of compatibility with every Linux distribution or Alpine/musl.

See [the migration assessment](docs/native-packaging.md) for scope and evidence.
