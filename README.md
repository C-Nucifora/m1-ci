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

Diagnostics land as **inline annotations** on the pull request, on their
exact lines. If a `parameters.m1cfg` sits beside your `Project.m1prj`, the
type checker auto-discovers it, so the type check is parameter-type-aware
with no extra configuration.

Notable inputs (see [`check.yml`](.github/workflows/check.yml) for the full
list and current defaults): `fail-on-warning` to also fail on
warning-severity diagnostics, `sarif-upload` to push lint findings to GitHub
code scanning (grant `permissions: security-events: write`), `lint-baseline`
to gate on only *new* lint findings (the incremental-adoption path, below),
per-check `run-*` switches, and per-tool version overrides.

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
```

Hooks download the pinned prebuilt binaries once (cached under
`~/.cache/m1-ci`); hosts without a prebuilt binary build from source at the
same pinned tag, as does CI when a release asset is unavailable.

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
