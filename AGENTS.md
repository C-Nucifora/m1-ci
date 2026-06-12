# AGENTS.md — m1-ci

Guidance for coding agents working in this repository.

## Purpose

The CI/pre-commit distribution layer for the M1 toolchain: a reusable GitHub
Actions workflow (`check.yml`) plus matching pre-commit hooks that install
pinned tool releases and run them over a consumer's M1 project. Its product
is **reproducibility** — one m1-ci tag pins one exact toolchain for both CI
and local hooks, so results can't drift between the two or change under a
consumer without a deliberate bump.

## Things that are deliberate (don't "fix" them)

- **`tools.env` is the single source of truth** for tool versions. The
  defaults in `check.yml` must match it, and CI enforces that — when the
  tools release, bump `tools.env`, bump `check.yml`'s defaults, and cut a new
  m1-ci release. Never point a default at `latest`.
- **Each check is its own job** so they run in parallel and a consumer sees
  every failure category in one run. Don't fold them into one job for
  tidiness.
- **Prebuilt binaries first, source build as fallback** — and the fallback
  builds the *same pinned tag*. Installation must never silently produce a
  different tool version than `tools.env` names.
- **Script names contain spaces** (`Mission Critical Transcieve 500Hz.m1scr`
  is normal). File lists are NUL-delimited; any new shell in the workflow or
  hooks must survive spaces in paths.
- **Failures gate on error severity by default**; warnings annotate. The
  stricter mode is the consumer's opt-in (`fail-on-warning`), not the
  default.

## Releasing

Bump `VERSION` in a PR; on merge, `release.yml` cuts the tag (idempotent,
also manually triggerable). The same PR must bump the self-referencing
`m1-ci-ref` default in `check.yml` and the pinned tag in
`examples/check.yml` — the `ci-ref-pin` CI job fails if either drifts from
`v$(cat VERSION)`.

After any upstream tool release (fmt/lint/typecheck/project), this repo is
the last step of the cascade: update `tools.env`, release, and consumers pick
up the new toolchain on their next deliberate bump.

## Testing

`tests/` contains self-test fixtures (an intentionally well-formed and an
intentionally failing M1 project) exercised by this repo's own CI — keep them
in sync with new tool behaviour (a new default-on rule can turn the "clean"
fixture red).
