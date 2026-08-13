# m1-ci

Reusable GitHub Actions workflows for [MoTeC M1](https://www.motec.com.au/)
script projects. Zero config — reference the workflow from your project and it
format-checks, lints, and type-checks every `.m1scr` with the
[M1 toolchain](https://github.com/C-Nucifora/m1-tools) on each push and pull
request.

## Usage

Add `.github/workflows/m1.yml` to your M1 project, pinning the
[latest release](https://github.com/C-Nucifora/m1-ci/releases):

```yaml
name: M1

on:
  push:
  pull_request:

jobs:
  check:
    uses: C-Nucifora/m1-ci/.github/workflows/check.yml@vX.Y.Z
    with:
      scripts-path: UQR-EV/01.00/Scripts
      project-file: UQR-EV/01.00/Project.m1prj
```

A ready-to-copy version lives in [`examples/check.yml`](examples/check.yml).

## What it runs

Each check is its **own job**, so they run in parallel and report
independently — one PR can show *Format ✗ / Lint ✓ / Type check ✗* at once
instead of revealing failures one at a time:

| Check (job) | Tool | Fails when… |
|-------------|------|-------------|
| Format check | `m1-fmt --check` | a script is not canonically formatted |
| Lint | `m1-lint` | an error-severity lint fires (or a syntax error) |
| Type check | `m1-typecheck` | an error-severity type diagnostic fires |
| Project validation | `m1-project validate` | an error-level structural finding in `Project.m1prj` (skips silently when no project file exists) |
| DBC export check (opt-in, `run-dbc-export-check`) | `m1-dbc export --check` | a committed `.dbc` export has gone stale against its `.m1dbc` source (no-op when `m1-tools.toml` has no `[dbc]` section) |

Diagnostics land as **inline annotations** on the pull request, on their
exact lines. If a `parameters.m1cfg` sits beside your `Project.m1prj`, the
type checker auto-discovers it, so the type check is parameter-type-aware
with no extra configuration.

Notable inputs (see [`check.yml`](.github/workflows/check.yml) for the full
list and current defaults): `fail-on-warning` to also fail on
warning-severity diagnostics (honoured by every check, `m1-fmt` included),
`sarif-upload` to push lint findings to GitHub code scanning (grant
`permissions: security-events: write`), `changed-files-only` to run the fmt
and lint gates on just the PR's changed scripts, `lint-baseline` to gate on
only *new* lint findings (the incremental-adoption path, below), per-check
`run-*` switches, and per-tool version overrides.

`changed-files-only` narrows only the fmt/lint **gates**, never the
`sarif-upload` — the SARIF always covers the full project. A code-scanning
category replaces its prior analysis, so a partial upload would wrongly report
untouched files' pre-existing alerts as fixed.

### Turning the lint gate on for an existing project

A project with pre-existing lint findings can adopt the gate without first
reaching zero: snapshot the current findings into a baseline once, commit it,
and the Lint check then reports only **new** findings.

```sh
# from your project root, with the pinned m1-lint installed
m1-lint --write-baseline .m1lint-baseline.json UQR-EV/01.00/Scripts/*.m1scr
git add .m1lint-baseline.json
```

Then point the workflow at it:

```yaml
with:
  scripts-path: UQR-EV/01.00/Scripts
  lint-baseline: .m1lint-baseline.json
```

The baseline is applied to both the lint gate and the SARIF render, so
suppressed pre-existing findings don't resurface as code-scanning alerts.
Shrink the baseline as you fix the backlog.

## One pin, one toolchain

The tool versions are pinned by each m1-ci release
([`tools.env`](tools.env)), so `m1-ci@vX.Y.Z` installs a **frozen,
reproducible toolchain** — a new (possibly stricter) tool release can't
change your CI result until you bump the tag deliberately. Set
`tools-version: latest` to track the newest tools instead.

The same gates run locally as [pre-commit](https://pre-commit.com) hooks,
reading the same `tools.env`, so a commit is checked with the exact tools and
versions CI uses:

```yaml
repos:
  - repo: https://github.com/C-Nucifora/m1-ci
    rev: vX.Y.Z          # same tag as `uses: …@vX.Y.Z` in your workflow
    hooks:
      - id: m1-fmt
      - id: m1-lint
      - id: m1-typecheck
      - id: m1-project-validate
      - id: m1-dbc-export-check
```

| Hook | Runs | Triggers on |
|------|------|-------------|
| `m1-fmt` | `m1-fmt --check` | `*.m1scr` |
| `m1-lint` | `m1-lint` | `*.m1scr` |
| `m1-typecheck` | `m1-typecheck` | `*.m1scr` |
| `m1-project-validate` | `m1-project validate --project` | `Project.m1prj` |
| `m1-dbc-export-check` | `m1-dbc export --check` | `*.m1dbc`, `*.dbc`, `m1-tools.toml` |

`m1-dbc-export-check` catches a `.m1dbc` edited without regenerating its
committed Vector `.dbc` export. It passes no filenames: the run is whole-config,
driven by the `[dbc]` section of the `m1-tools.toml` found by walking up from
the working directory, and `--check` writes nothing into your tree (it
generates into a temp dir and compares). Exit codes mirror the CLI — `0` in
sync, `1` an export is stale (run `m1-dbc export` and commit), `2` the config
or a file could not be read. A repo whose `m1-tools.toml` has no `[dbc]`
section — or that has no `m1-tools.toml` at all — is a **clean no-op**, so the
hook is safe to enable everywhere, including in repos that ship no CAN
databases.

Hooks download the pinned prebuilt binaries once (cached under
`~/.cache/m1-ci`); hosts without a prebuilt binary build from source at the
same pinned tag, as does CI when a release asset is unavailable.

Downloaded binaries are **verified before first use**: with an authenticated
[GitHub CLI](https://cli.github.com) the hook checks the release asset's
GitHub build provenance (`gh attestation verify`); without one the download
is refused with remediation steps. Set `M1_CI_ALLOW_UNVERIFIED=1` to accept
an unverified download explicitly (loudly warned) — e.g. on an air-gapped
mirror you trust. The source-build fallback is unaffected (it builds the
pinned tag from source rather than executing a downloaded artifact).

## Releasing

Bump [`VERSION`](VERSION) in a PR; on merge, `release.yml` cuts the matching
tag and GitHub Release. CI enforces that the workflow's tool-version defaults
match `tools.env` and that the self-referencing pins match `VERSION`, so the
pins can't drift from the release.

## License

GPL-3.0 — see [LICENSE](LICENSE).

## Trademark

Independent, community-built open-source tooling for the MoTeC® M1 script
language. Not affiliated with, authorised, or endorsed by MoTeC Pty Ltd.
"MoTeC" and "M1" are trademarks of MoTeC Pty Ltd.
