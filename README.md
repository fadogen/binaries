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

### What the sync will not decide for you

- A new major line, `postgresql@19` say, is reported in the job summary, never
  added on its own.
- Patches Homebrew applies from its own tap or inline in the formula cannot be
  fetched, so they are counted and reported rather than replayed.
- A recipe whose line no longer exists upstream is reported as unresolved and
  left alone.

## Tests

```bash
bats tests/                        # unit suite, runs against fixtures
SKIP_NETWORK_TESTS=1 bats tests/   # same, without the live API checks
```
