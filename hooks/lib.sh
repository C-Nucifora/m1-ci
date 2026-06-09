# Shared helpers for the m1-ci local pre-commit hooks.
#
# These hooks run the SAME pinned tool binaries that the CI reusable workflow
# installs, so a developer's pre-commit run matches CI exactly. The pinned
# versions live in ../tools.env (the single source of truth).
#
# The tool binary is downloaded once from the tool repo's public GitHub release
# (no `gh` / auth needed — a plain HTTPS download of a public asset) and cached
# under $M1_CI_CACHE (default ~/.cache/m1-ci/bin), keyed by tool+version, so
# subsequent runs are instant. If no prebuilt asset exists for the host
# platform, it falls back to `cargo install` from the pinned tag.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HOOKS_DIR/.." && pwd)"
CACHE_DIR="${M1_CI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/m1-ci/bin}"

# Read M1_<KEY>_VERSION from tools.env (e.g. tool_version LINT -> v0.9.0).
tool_version() {
  local key="$1" var="M1_${1}_VERSION" line
  line="$(grep -E "^${var}=" "$REPO_DIR/tools.env" | head -n1)" || true
  if [ -z "$line" ]; then
    echo "m1-ci hook: ${var} not found in tools.env" >&2
    exit 1
  fi
  printf '%s\n' "${line#*=}"
}

# Map the host OS/arch to the release asset suffix published by the tool repos.
# Published targets: aarch64-apple-darwin, x86_64-pc-windows-msvc.exe,
# x86_64-unknown-linux-gnu. Anything else returns empty -> cargo fallback.
asset_suffix() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin)
      case "$arch" in
        arm64 | aarch64) echo "aarch64-apple-darwin" ;;
        *) echo "" ;; # Intel macs build from source
      esac
      ;;
    Linux)
      case "$arch" in
        x86_64 | amd64) echo "x86_64-unknown-linux-gnu" ;;
        *) echo "" ;;
      esac
      ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      case "$arch" in
        x86_64 | amd64) echo "x86_64-pc-windows-msvc.exe" ;;
        *) echo "" ;;
      esac
      ;;
    *) echo "" ;;
  esac
}

# Ensure the pinned `<tool>` binary is cached; print its path on stdout.
ensure_tool() {
  local tool="$1" version suffix asset url dest
  version="$(tool_version "$(printf '%s' "${tool#m1-}" | tr '[:lower:]' '[:upper:]')")"
  suffix="$(asset_suffix)"

  local ext=""
  case "$suffix" in *.exe) ext=".exe" ;; esac
  dest="$CACHE_DIR/${tool}-${version}${ext}"

  if [ -x "$dest" ]; then
    printf '%s\n' "$dest"
    return 0
  fi

  mkdir -p "$CACHE_DIR"

  if [ -n "$suffix" ]; then
    asset="${tool}-${suffix}"
    url="https://github.com/C-Nucifora/${tool}/releases/download/${version}/${asset}"
    echo "m1-ci hook: fetching ${tool} ${version} ($suffix)…" >&2
    if curl -fsSL -o "$dest.tmp" "$url"; then
      # Verify GitHub-native build provenance when gh is available and
      # authenticated (mirrors the CI install action); degrade gracefully —
      # a release predating attestation, or no gh, only warns (#23).
      if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        if gh attestation verify "$dest.tmp" --repo "C-Nucifora/${tool}" >/dev/null 2>&1; then
          echo "m1-ci hook: verified build provenance for ${tool} ${version}." >&2
        else
          echo "m1-ci hook: warning: no verifiable build provenance for ${tool} ${version}; proceeding." >&2
        fi
      fi
      chmod +x "$dest.tmp"
      mv "$dest.tmp" "$dest"
      printf '%s\n' "$dest"
      return 0
    fi
    rm -f "$dest.tmp"
    echo "m1-ci hook: no prebuilt ${tool} for this platform; building from source…" >&2
  else
    echo "m1-ci hook: no prebuilt asset target for $(uname -s)/$(uname -m); building ${tool} from source…" >&2
  fi

  # Fallback: cargo install the pinned tag into the cache dir.
  if ! command -v cargo >/dev/null 2>&1; then
    echo "m1-ci hook: cannot install ${tool}: no prebuilt binary and cargo is not available." >&2
    exit 1
  fi
  cargo install --locked --git "https://github.com/C-Nucifora/${tool}.git" --tag "$version" \
    --root "$CACHE_DIR/cargo-${tool}-${version}" "$tool" >&2
  cp "$CACHE_DIR/cargo-${tool}-${version}/bin/${tool}${ext}" "$dest"
  printf '%s\n' "$dest"
}
