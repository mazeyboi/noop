#!/usr/bin/env bash
# Prints a JSON array of the Swift packages under <root>/Packages that have a test directory.
# New upstream packages are picked up automatically, so the fork's CI never drifts from upstream's.
# Usage: list-packages.sh [root]
set -euo pipefail
root="${1:-.}"
out=""
while IFS= read -r name; do
  out="${out:+$out,}\"$name\""
done < <(
  for d in "$root"/Packages/*/; do
    [ -f "$d/Package.swift" ] && [ -d "$d/Tests" ] && basename "$d"
  done | LC_ALL=C sort
)
printf '[%s]\n' "$out"
