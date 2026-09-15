# Service packaging migration

## Decision and scope

Keep Fadogen's native, independently versioned services and existing Rust installer.
Replace the Unix database/cache source builds with one bottle resolver, one runtime
assembler, two binary-format relocation backends and a common verification and
publication path. Windows remains a vendor repackage; PHP remains a source build
through static-php-cli. This migration changes how the services are manufactured,
not how users obtain them.

The removed implementation maintained service recipes, transitive dependency
recipes, source patches, upstream recipe synchronization, duplicate bottle/source
builders and tests of those obsolete paths. The remaining maintenance includes
upstream availability, runtime dependency closure, package layout, signing,
platform compatibility and functional qualification. Repackaging does not remove
those responsibilities or make all vendor distributions interchangeable.

## Findings from the previous implementation

- Partial publication already existed. Successful platforms were uploaded despite
  other jobs failing; an all-or-nothing release was not the cause of all retries.
- The metadata job checked out a different revision from the synchronized build
  jobs and recalculated dependency fingerprints. A successful build could therefore
  be labelled with stale inputs and selected again on the following schedule.
- Failed input downloads were sometimes treated as empty metadata, and update
  failures were suppressed. The replacement fails closed on storage errors.
- Formula synchronization tracked versions but could not eliminate maintenance of
  upstream compiler fixes and dependency recipes.
- Removing old filenames immediately could race clients using previous metadata.

## Input and output contracts

A plan records the selected service major, exact version, OS/architecture, formula,
component bottle digests, source references and packager digest. Build jobs reject
code changes after planning. Each output receipt carries the same fingerprint and
the digest of the compressed bytes actually tested. Metadata accepts only receipts
matching that plan and verification digest.

Runtime kegs remain distinct, preserving relative PostgreSQL resource lookup and
avoiding accidental overwrites of similarly named libraries. Mach-O dependencies
become `@loader_path` references. ELF dependencies use `$ORIGIN` paths and the
system interpreter. Linux also bundles GCC's shared runtimes, including libatomic,
without retaining the compiler or its build-tool dependency tree. Unresolved or
ambiguous dependencies are errors.

SQL wrappers compute `basedir`, plugin, socket and PID paths relative to the package
and data directory. MariaDB has two narrowly guarded installer quoting changes.
It also pre-registers `#rocksdb` with `--ignore-db-dir`, the configuration used in the
previous functional qualification. The MySQL recipe being replaced did not enable
MeCab; vendor-only optional modules are not implicitly added to the new contract.
No global Homebrew prefix or user configuration is rewritten.

The metadata schema (`latest`, `sha256`, `filename`, `deps`) stays the same. Archive
names become content-addressed. The first release rebuilds the configured catalogue
because its packaging fingerprint changes. Subsequent schedules select only changed
inputs, failed/missing entries or explicitly forced service lines.

## Qualification status

Local experiments and GitHub's PR jobs are separate evidence. Successful earlier
prototype tests do not certify the production implementation in this PR. The
committed runtime verifier repeats the required checks on each newly generated
archive. Results, commands, server logs and backup/restore evidence are retained
as workflow artifacts, with the tested archive checksum.

The PR does not execute production signing or R2 publication. Those paths require
the main-branch secrets. Windows execution and a full graphical Fadogen installation
are outside the checks implemented here; the Windows gate explicitly reports
`structural-only`. No live application data or installed runtime is used by tests.

## Sources

- [Homebrew bottles](https://docs.brew.sh/Bottles): prebuilt packages and relocation.
- [Homebrew JSON API](https://docs.brew.sh/Querying-Brew): formula and bottle metadata.
- [Homebrew source](https://github.com/Homebrew/brew): reference relocation behaviour;
  this packager uses private runtime paths instead of installing a Homebrew prefix.
- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners):
  ARM64/macOS/Linux labels and public standard-runner availability.

The platform/version catalogue is resolved live by the plan job. Missing bottles
remain visible failures, not an invitation to silently revive source compilation.
