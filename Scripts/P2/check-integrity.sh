#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if [[ -n "$(git ls-files --unmerged)" ]]; then
  printf 'error: the index contains unresolved merge entries\n' >&2
  git ls-files --unmerged >&2
  exit 1
fi

git diff --check
git diff --cached --check
if [[ -n "${GITHUB_BASE_REF:-}" ]] &&
   git rev-parse --verify --quiet "origin/${GITHUB_BASE_REF}" >/dev/null; then
  git diff --check "origin/${GITHUB_BASE_REF}...HEAD"
fi

scan_paths=(
  Pane
  Tests
  Pane.xcodeproj
  Package.swift
  README.md
  docs
  .github
  Scripts
)

existing_paths=()
for path in "${scan_paths[@]}"; do
  if [[ -e "$path" ]]; then
    existing_paths+=("$path")
  fi
done

if rg -n '^(<<<<<<< |=======|>>>>>>> )' "${existing_paths[@]}"; then
  printf 'error: literal merge-conflict markers found\n' >&2
  exit 1
fi

/usr/bin/python3 Tests/Compatibility/Scripts/validate-compatibility-evidence.py

printf 'P2 integrity checks passed\n'
