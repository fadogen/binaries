# Fadogen Binaries

Pre-compiled binaries for the [Fadogen](https://github.com/fadogen/app) macOS application.

## Staying current with Homebrew

Database services are built from the recipes in `.github/scripts/recipes`. Each
recipe pairs a metadata block, meaning version, source URL and checksum, with
the `build()` function that turns that source into a portable bundle.

The metadata block is not maintained by hand. `.github/scripts/sync-upstream.sh`
reads the Homebrew formula each recipe tracks and rewrites the block to match:

```bash
.github/scripts/sync-upstream.sh check   # report the drift, write nothing
.github/scripts/sync-upstream.sh apply   # rewrite the outdated recipes
```

The `Build Services` workflow runs `apply` every night, commits whatever moved,
and builds from that commit in the same run. Nothing needs a human in the loop.
A push to `main` skips the sync, so a deliberate edit is never overwritten.

### How a recipe finds its formula

A recipe is named after the major line it tracks, `mysql@9` rather than
`mysql@9.7`, so a Homebrew rename inside that line changes nothing here. The
resolver picks the formula currently serving the line, whether that is the base
formula, `redis` for the 8 line, or a versioned one, `mysql@9.7` for the 9 line.

A recipe whose source URL differs from the formula's, such as `nss@3` and its
bundled NSPR tarball, gets its checksum recomputed from the artefact it really
downloads. When that URL needs more than a version number, the recipe defines an
`upstream_extra` hook that resolves the missing fields itself.

### Keeping up with the formula itself, not just its version

A recipe transposes a formula's build logic by hand. When Homebrew changes that
logic without changing the version, adding a dependency, a patch, or a step in
`install`, nothing about the version tells you.

Each recipe therefore carries `BREW_FORMULA_REVIEWED`, a fingerprint of the
formula file with the volatile parts stripped out: the `bottle` block, the
`livecheck` block, and the source coordinates the sync already tracks. A version
bump or a bottle rebuild leaves that fingerprint alone; a changed `depends_on`,
`patch` or `install` block moves it.

When it moves, the run summary links to the formula history. Read the diff, carry
over what matters into `build()`, then record that you have looked:

```bash
.github/scripts/sync-upstream.sh review redis@8
```

The version keeps being synced in the meantime. A build-logic change must never
strand a security fix behind a review.

### What the sync will not decide for you

- A new major line, `postgresql@19` say, is reported in the job summary, never
  added on its own.
- Patches Homebrew applies from its own tap or inline in the formula cannot be
  fetched, so they are counted and reported rather than replayed.
- A recipe whose line no longer exists upstream is reported as unresolved and
  left alone.

## Provenance

Every bundle carries a `PROVENANCE.txt` listing each component it was built
from: version, licence, source archive and SHA-256 checksum. Several of these
components are copyleft, Redis and MariaDB among them, and their licences
require whoever receives the binary to be told where the corresponding source
is. Nothing here is built from modified sources, so naming the exact upstream
archive and its checksum answers that.

The licence expressions come from the same place as the versions: the sync
records `PACKAGE_LICENSE` from the formula, whether or not the version moved.

## Tests

```bash
bats tests/                        # unit suite, runs against fixtures
SKIP_NETWORK_TESTS=1 bats tests/   # same, without the live API checks
```
