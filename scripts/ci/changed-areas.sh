#!/usr/bin/env bash
# Decides which checks a push needs (docs/development.md#continuous-integration) and writes
# `code=true|false` and `docs=true|false` to $GITHUB_OUTPUT.
#
# Compares the push's own commits ($BEFORE..HEAD); for a new branch, everything since it left
# main. Anything unclear (a manual run, a force push past history we don't have) runs everything.
set -euo pipefail

output=${GITHUB_OUTPUT:-/dev/stdout}
base=
if [[ $GITHUB_EVENT_NAME == push && -n ${BEFORE:-} && ! $BEFORE =~ ^0+$ ]] && git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
  base=$BEFORE
elif [[ $GITHUB_EVENT_NAME == push && $GITHUB_REF != refs/heads/main ]]; then
  base=$(git merge-base origin/main HEAD 2>/dev/null || true)
fi
if [[ -z $base ]]; then
  echo "Running everything: no base to compare with."
  echo "code=true" >> "$output"
  echo "docs=true" >> "$output"
  exit 0
fi

files=$(git diff --name-only "$base" HEAD)
echo "Changed since ${base:0:7}:"
echo "${files:-(nothing)}"
code=false
docs=false
# App, CLI and core code, their tests and the package; the test workflow and its scripts
# too, so a change to them proves itself.
if grep -qE '^(Sources|Tests|App)/|^Package\.(swift|resolved)$|^\.github/workflows/tests\.yml$|^scripts/ci/' <<< "$files"; then
  code=true
fi
# The docs check also covers code: every Swift file must be in a "Where things live" table,
# and doc paths in source comments must exist.
if [[ $code == true ]] || grep -qE '^docs/|^README\.md$|^\.claude/CLAUDE\.md$|^scripts/check-docs\.swift$' <<< "$files"; then
  docs=true
fi
echo "code=$code docs=$docs"
echo "code=$code" >> "$output"
echo "docs=$docs" >> "$output"
