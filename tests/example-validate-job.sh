#!/usr/bin/env bash
set -euo pipefail

file="examples/check.yml"

need() {
  local pattern="$1" message="$2"
  if grep -Eq "$pattern" "$file"; then
    echo "ok: $message"
  else
    echo "::error::$message"
    exit 1
  fi
}

need '^  validate:$' "example workflow declares a validate job"
need '^      - uses: actions/setup-python@v6$' "validate job sets up Python"
need 'python -m pip install -r dev-requirements\.txt' "validate job installs dev-requirements.txt"
need 'python -m scripts\.validate_m1prj UQR-AV/01\.00/Project\.m1prj' "validate job runs validate_m1prj"
need 'python -m scripts\.validate_m1cfg parameters\.m1cfg' "validate job runs validate_m1cfg schema-only"
need 'python -m scripts\.validate_m1scr' "validate job runs validate_m1scr"

echo "PASS: example validate job includes the XML/structure validator gate"
