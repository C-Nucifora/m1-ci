# m1-ci

Reusable GitHub Actions workflows for [MoTeC M1](https://www.motec.com.au/) script
projects. Zero config — reference the workflow from your project and it
format-checks, lints, and type-checks every `.m1scr` with the
[C-Nucifora M1 toolchain](https://github.com/C-Nucifora/m1-tools) on each push
and pull request.

## Usage

Add `.github/workflows/m1.yml` to your M1 project:

```yaml
name: M1

on:
  push:
  pull_request:

jobs:
  check:
    uses: C-Nucifora/m1-ci/.github/workflows/check.yml@v0.9.3
    with:
      scripts-path: UQR-EV/01.00/Scripts
      project-file: UQR-EV/01.00/Project.m1prj
```

A ready-to-copy version lives in [`examples/check.yml`](examples/check.yml).

## What it runs

The reusable [`check.yml`](.github/workflows/check.yml) installs the toolchain and
runs it over every `.m1scr` it finds. Each check is its **own job**, so they run
in parallel and report **independently** — a failing format check no longer skips
the lint and type check. You get a separate ✓/✗ status on the PR for each:

| Check (job) | Tool | Fails when… |
|-------------|------|-------------|
| Format check (m1-fmt) | `m1-fmt --check` | a script is not canonically formatted |
| Lint (m1-lint) | `m1-lint` | an **error**-severity lint fires (or a syntax error) |
| Type check (m1-typecheck) | `m1-typecheck` | an **error**-severity type diagnostic fires |
| Project validation (m1-project) | `m1-project validate` | an error-level structural finding in `Project.m1prj` (skipped silently when no project file exists) |

Because the jobs are independent, a single PR can show e.g. *Format check ✗ /
Lint ✓ / Type check ✗* at once — you see every problem in one run instead of
fixing formatting just to discover the next failure.

Set [`fail-on-warning`](#inputs) to also fail on warning-severity diagnostics
(line length, complexity, `eq`-over-`==`, …), which otherwise only annotate.

Set [`sarif-upload`](#inputs) to additionally push the lint findings to GitHub
**code scanning** (Security tab, per-rule alert dismissal, new-alerts diffing on
PRs) via `m1-lint --format sarif` + `github/codeql-action/upload-sarif`. The
calling job must grant `permissions: security-events: write`:

```yaml
jobs:
  check:
    permissions:
      contents: read
      security-events: write
    uses: C-Nucifora/m1-ci/.github/workflows/check.yml@v0.12.0
    with:
      sarif-upload: true
```

If a `parameters.m1cfg` sits beside your `Project.m1prj`, the type checker
auto-discovers it and uses its parameter **value types and units** — so the type
check is parameter-type-aware with no extra configuration.

Diagnostics are emitted as **inline annotations** on the pull request — each
`m1-lint` / `m1-typecheck` finding lands on its exact line, and unformatted files
are flagged by `m1-fmt`.

Script names containing spaces (e.g. `CAN.Mission Critical Transcieve 500Hz.m1scr`)
are handled correctly (NUL-delimited file lists).

## Local checks (pre-commit)

The same gates run locally as [pre-commit](https://pre-commit.com) hooks, so a
developer's commit is checked with the **exact tools and versions CI uses**. Add
to your project's `.pre-commit-config.yaml`, pinning the **same m1-ci tag** as your
workflow:

```yaml
repos:
  - repo: https://github.com/C-Nucifora/m1-ci
    rev: v0.7.0          # same tag as `uses: …@v0.7.0` in your workflow
    hooks:
      - id: m1-fmt
      - id: m1-lint
      - id: m1-typecheck
      - id: m1-project-validate
```

Then `pre-commit install`. Each hook downloads (once, cached under
`~/.cache/m1-ci`) the pinned tool binary named in [`tools.env`](tools.env) — the
same version `check.yml` installs — so there is nothing to install by hand.
Prebuilt binaries cover macOS (Apple Silicon), Windows, and Linux x86-64; other
hosts build from source via `cargo` (the pinned tag).

Because both halves read `tools.env` (CI enforces that `check.yml`'s defaults
match it), **one m1-ci tag pins one toolchain for both local and CI** — they can't
drift.

## How the tools are installed

`check.yml` downloads the **prebuilt release binaries** published by each tool
repo (`m1-fmt` / `m1-lint` / `m1-typecheck` / `m1-project` — the last lives
under `nedlane/`, the rest under `C-Nucifora/`) for the runner. If a release is
unavailable for the requested version, it transparently falls back to building
from source (`cargo install --git`).

The tool versions are **pinned by this m1-ci release** — the `fmt-version` /
`lint-version` / `typecheck-version` defaults baked into `check.yml` name exact
tags. So pinning `m1-ci@vX.Y.Z` installs a **frozen, reproducible toolchain**: a
new (possibly stricter) tool release can't change your CI result until you bump
the m1-ci tag. To track the newest tools instead, set `tools-version: latest` (or
override a single tool's `*-version`).

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `scripts-path` | `.` | Directory searched recursively for `.m1scr` files. |
| `project-file` | `""` | `Project.m1prj` for symbol-aware type checking. Empty = `m1-typecheck` auto-discovers the nearest one upward from each script. |
| `fmt-version` | `v0.8.2` | `m1-fmt` release to install: a tag, or `latest`. |
| `lint-version` | `v0.12.2` | `m1-lint` release to install: a tag, or `latest`. |
| `typecheck-version` | `v0.25.5` | `m1-typecheck` release to install: a tag, or `latest`. |
| `tools-version` | `""` | Master override (advanced). Empty = use the pinned per-tool versions above. `latest` = newest of every tool; a single tag forces all three (they are independently versioned). |
| `run-fmt` | `true` | Run the formatter check. |
| `run-lint` | `true` | Run the linter. |
| `run-typecheck` | `true` | Run the type checker. |
| `project-version` | `v0.3.1` | `m1-project` release to install: a tag, or `latest`. |
| `run-project-validate` | `true` | Validate `Project.m1prj` structure with `m1-project validate` (explicit `project-file`, else auto-discovered; skips silently when absent). |
| `sarif-upload` | `false` | Also emit `m1-lint` findings as SARIF and upload to GitHub **code scanning**. The calling job must grant `permissions: security-events: write`, and code scanning must be available on the repo (public, or Advanced Security). |
| `fail-on-warning` | `false` | Fail on warning-severity diagnostics, not just errors. |

## Pinning

`@main` always tracks the latest workflow **and** the newest pinned tool defaults
on `main`. For reproducible CI, pin to a tag — the tag freezes both the workflow
and the M1 toolchain versions it installs, e.g.
`uses: C-Nucifora/m1-ci/.github/workflows/check.yml@v0.9.3`. Bump the tag
deliberately when you want the newer toolchain.

## Releasing

Releases are automated. Bump the version in [`VERSION`](VERSION) in a PR; when it
merges to `main`, [`.github/workflows/release.yml`](.github/workflows/release.yml)
cuts the matching `vX.Y.Z` tag + GitHub Release (with generated notes) if one
doesn't already exist. The job is idempotent — re-running it for an existing
version is a no-op — and can also be triggered manually from the Actions tab.

When you bump `VERSION`, also bump the `m1-ci-ref` input default in
[`check.yml`](.github/workflows/check.yml) and the pinned tag in
[`examples/check.yml`](examples/check.yml) to the matching `vX.Y.Z`. CI's
`ci-ref-pin` job enforces this — it fails if either drifts from `v$(cat
VERSION)` — so the ref m1-ci checks itself out at can never lag the release.

## License

GPL-3.0 — see [LICENSE](LICENSE).

## Trademark

Independent, community-built open-source tooling for the MoTeC® M1 script
language. Not affiliated with, authorised, or endorsed by MoTeC Pty Ltd.
"MoTeC" and "M1" are trademarks of MoTeC Pty Ltd.
