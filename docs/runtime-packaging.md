# Runtime workflow migration

The remaining workflows had version-only update detection, duplicated publication
logic, and storage reads that treated any error as an empty catalogue. Several
scheduled workflows had been disabled after repository inactivity. Reactivating
them unchanged would not address those failure modes.

The shared runtime publisher now uses the same final-archive receipts and storage
transport as the service publisher. Failed targets retain their published entry;
successful targets advance independently. An unsuccessful read, upload or readback
prevents cleanup. Obsolete archives are removed only after all active references
are checked. Utility and PHP publication use separate concurrency groups and
disjoint object namespaces; services retain their own namespace.

## Choices

- Garage and macOS sshpass reuse Homebrew bottles and their runtime dependencies.
- Composer uses its official PHAR and SHA-256. Typesense uses its official HTTPS
  archives. Typesense does not expose an independent SHA-256 release manifest;
  the resolver hashes its HTTPS response and the builder checks those frozen bytes.
- Reverb retains its Laravel application, dependency lock and tests in
  `fadogen/laravel-reverb`. Binaries installs the exact committed lock and audits
  production dependencies before assembling the package. It never publishes a
  dependency update that it just created in an unmerged source checkout.
- PHP retains static-php-cli because the required native CLI/FPM extension set
  is not replaced by a generic PHP archive. The stable SPC release and its asset
  digests are pinned. PHP's full version and source checksum are planned before
  execution; the source/dependency snapshot determines recompilation. Required
  dependency downloads use upstream prebuilt libraries where available. The
  download selection excludes suggestions, matching the build's extension set.
- Windows PHP keeps the official NTS x64 ZIP. The manifest determines its compiler
  ABI; Xdebug and Redis versions and bytes are included in the fingerprint.
- All macOS packaging targets ARM64 on macOS 26 runners. Linux uses Ubuntu 24.04
  ARM64 and x64. PHP additionally executes on Windows x64; the previously migrated
  database Windows packages still have structural-only qualification.

The native PHP dependency check still requires its target runner and fresh source
downloads. Compilation is skipped when its completed input snapshot is unchanged.
This is not a claim that every daily check is free of downloads or runner time,
nor a guarantee of byte-identical builds across different compiler images.

## Qualification gates

The workflow runs on pull requests without R2 publication or production signing.
Only the final compressed archive is tested: extraction, movement to an unrelated
path containing spaces, execution and restart. The receipt binds those tested
bytes to the immutable source plan. macOS native tests deny Homebrew and installed
Fadogen runtimes; Linux checks dynamic bindings and hides Linuxbrew on its disposable
runner. PHP checks its full selected extension set, Xdebug loading, CLI and FPM/CGI
requests, SQLite persistence, Intl, Sodium and GD. Windows runner execution does
not establish independence from the Microsoft runtime already on that image.

Reverb's source update must be merged before its new publication can pass the
production dependency audit. Its previous lock contains advisories. This migration
must not be used to bypass that gate.

The old PHP build manager, patch hooks and individual utility workflows are removed.
SPC's pinned source recipe already excludes the problematic libsodium release and
contains the Linux IMAP compiler adjustment; the old IMAP hook ran before extraction.
CI compilation remains the acceptance test for replacing those hooks.

## Fadogen integration boundary

Archive extraction layouts and existing metadata field names remain compatible
with Fadogen's current installers. A changed `deps` fingerprint produces a new
archive and catalogue digest even when the upstream version stays the same.
The application must compare that digest to offer a same-version update. The
previous datastore change covers databases; singleton orchestration still compares
only the version and needs a separate consumer change for Garage, Typesense and
Reverb. Publication alone does not implement that UI behavior.

## References

- [Composer downloads](https://getcomposer.org/download/)
- [Static PHP CLI v2 manual](https://static-php.github.io/v2-docs/en/guide/manual-build.html)
- [Typesense installation](https://typesense.org/docs/guide/install-typesense.html)
- [Garage quick start](https://garagehq.deuxfleurs.fr/documentation/quick-start/)
- [Laravel Reverb](https://laravel.com/docs/12.x/reverb)
- [GitHub's macOS signing procedure](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
