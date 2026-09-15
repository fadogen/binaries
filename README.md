# Fadogen Binaries

Native runtimes downloaded by [Fadogen](https://github.com/fouteox/tauri-fadogen).
Database and cache engines are **repackaged from Homebrew bottles**, together with
their runtime dependencies. Users do not install Homebrew. PHP continues to use
static-php-cli; the independent Composer, Garage, SSHpass and Typesense workflows
remain separate.

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
architectures. These choices do not change the other workflows' platform policy.

## Build and verify locally

Python 3.12+ is the only Python runtime dependency. Run on the target architecture:
macOS needs `otool`, `install_name_tool` and `codesign`; Linux needs `patchelf`,
`readelf` and `ldd`. Functional tests also use the system `openssl`. Homebrew itself
is not invoked or installed by the packager.

```sh
python3 .github/scripts/package-services.py plan \
  --services postgresql --majors 18 --os darwin --arch arm64 \
  --output package-plan.json
python3 .github/scripts/package-services.py build \
  --plan package-plan.json --id postgresql-18-darwin-arm64
python3 .github/scripts/package-services.py verify \
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
job, which rereads the current metadata and merges those entries. Failed versions
and other platforms remain intact. Production runs are serialized; storage access
errors fail the job instead of replacing metadata with an empty object.

Old content-addressed archives are retained. Immediate deletion would break a
client still holding previous metadata. Retention/garbage collection needs a
separate policy; this workflow does not pretend that storage growth is free.
GitHub stores small plans, receipts and test evidence for seven days, not the
runtime archives or a permanent multi-gigabyte cache.

Pull requests run Unix packaging and runtime qualification without signing secrets,
R2 writes or attestations. Windows keeps its existing vendor downloader and adds ZIP
integrity, required executable and PE x64 checks. **These are structural checks, not
Windows execution tests.** A missing release, source-only ZIP or incorrect layout
fails instead of being published as a working runtime. The Redis community source
is not equivalent to an official cross-platform Redis release.

## Tests

```sh
python3 -m unittest discover -s tests/python -v
uvx ruff@0.16.7 check .github/scripts/package-services.py .github/scripts/native_packages tests/python
uvx ruff@0.16.7 format --check .github/scripts/package-services.py .github/scripts/native_packages tests/python
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
