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
    uses: C-Nucifora/m1-ci/.github/workflows/check.yml@v0.2.0
    with:
      scripts-path: UQR-EV/01.00/Scripts
      project-file: UQR-EV/01.00/Project.m1prj
```

A ready-to-copy version lives in [`examples/check.yml`](examples/check.yml).

## What it runs

The reusable [`check.yml`](.github/workflows/check.yml) installs the toolchain and
runs it over every `.m1scr` it finds:

| Step | Tool | Fails the build when… |
|------|------|-----------------------|
| Format check | `m1-fmt --check` | a script is not canonically formatted |
| Lint | `m1-lint` | an **error**-severity lint fires (or a syntax error) |
| Type check | `m1-typecheck` | an **error**-severity type diagnostic fires |

Set [`fail-on-warning`](#inputs) to also fail on warning-severity diagnostics
(line length, complexity, `eq`-over-`==`, …), which otherwise only annotate.

If a `parameters.m1cfg` sits beside your `Project.m1prj`, the type checker
auto-discovers it and uses its parameter **value types and units** — so the type
check is parameter-type-aware with no extra configuration.

Diagnostics are emitted as **inline annotations** on the pull request — each
`m1-lint` / `m1-typecheck` finding lands on its exact line, and unformatted files
are flagged by `m1-fmt`.

Script names containing spaces (e.g. `CAN.Mission Critical Transcieve 500Hz.m1scr`)
are handled correctly (NUL-delimited file lists).

## How the tools are installed

`check.yml` downloads the **prebuilt release binaries** published by each tool
repo (`m1-fmt` / `m1-lint` / `m1-typecheck`) for the runner. If a release is
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
| `fmt-version` | `v0.4.1` | `m1-fmt` release to install: a tag, or `latest`. |
| `lint-version` | `v0.5.1` | `m1-lint` release to install: a tag, or `latest`. |
| `typecheck-version` | `v0.16.0` | `m1-typecheck` release to install: a tag, or `latest`. |
| `tools-version` | `""` | Master override (advanced). Empty = use the pinned per-tool versions above. `latest` = newest of every tool; a single tag forces all three (they are independently versioned). |
| `run-fmt` | `true` | Run the formatter check. |
| `run-lint` | `true` | Run the linter. |
| `run-typecheck` | `true` | Run the type checker. |
| `fail-on-warning` | `false` | Fail on warning-severity diagnostics, not just errors. |

## Pinning

`@main` always tracks the latest workflow **and** the newest pinned tool defaults
on `main`. For reproducible CI, pin to a tag — the tag freezes both the workflow
and the M1 toolchain versions it installs, e.g.
`uses: C-Nucifora/m1-ci/.github/workflows/check.yml@v0.2.0`. Bump the tag
deliberately when you want the newer toolchain.

## License

GPL-3.0 — see [LICENSE](LICENSE).

## Trademark

Independent, community-built open-source tooling for the MoTeC® M1 script
language. Not affiliated with, authorised, or endorsed by MoTeC Pty Ltd.
"MoTeC" and "M1" are trademarks of MoTeC Pty Ltd.
