#!/usr/bin/env bash
# Prints the next fork release tag for an upstream base version.
# Reads existing tag names (one per line) on stdin; N is one more than the highest
# v<base>-extras.<N> among them, or 0 if there is none.
# Usage: git tag -l | next-extras-tag.sh 12.0.0   ->  v12.0.0-extras.3
set -euo pipefail
base="${1:-}"
if ! [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: next-extras-tag.sh <major.minor.patch> < tags" >&2
  exit 2
fi
prefix="v${base}-extras."
max=-1
while IFS= read -r tag; do
  tag="${tag%$'\r'}"
  [[ "$tag" == "$prefix"* ]] || continue
  n="${tag#"$prefix"}"
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  (( 10#$n > max )) && max=$((10#$n))
done
echo "${prefix}$((max + 1))"
