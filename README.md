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
    uses: C-Nucifora/m1-ci/.github/workflows/check.yml@main
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

Diagnostics are emitted as **inline annotations** on the pull request — each
`m1-lint` / `m1-typecheck` finding lands on its exact line, and unformatted files
are flagged by `m1-fmt`.

Script names containing spaces (e.g. `CAN.Mission Critical Transcieve 500Hz.m1scr`)
are handled correctly (NUL-delimited file lists).

## How the tools are installed

`check.yml` downloads the **prebuilt release binaries** published by each tool
repo (`m1-fmt` / `m1-lint` / `m1-typecheck`) for the runner. If a release is
unavailable for the requested `tools-version`, it transparently falls back to
building from source (`cargo install --git`). Default `tools-version: latest`
means fixes to the toolchain (the same engine behind the M1 language server) flow
into your CI automatically; pin to a tag for reproducible builds.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `scripts-path` | `.` | Directory searched recursively for `.m1scr` files. |
| `project-file` | `""` | `Project.m1prj` for symbol-aware type checking. Empty = `m1-typecheck` auto-discovers the nearest one upward from each script. |
| `tools-version` | `latest` | Toolchain release to use: `latest`, or a tag like `v0.3.1` to pin all three tools. |
| `run-fmt` | `true` | Run the formatter check. |
| `run-lint` | `true` | Run the linter. |
| `run-typecheck` | `true` | Run the type checker. |
| `fail-on-warning` | `false` | Fail on warning-severity diagnostics, not just errors. |

## Pinning

`@main` always tracks the latest workflow. For reproducible CI, pin to a tag or
commit SHA instead, e.g. `uses: C-Nucifora/m1-ci/.github/workflows/check.yml@v0.1.0`.

## License

GPL-3.0 — see [LICENSE](LICENSE).
