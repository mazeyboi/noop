#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Packages/A/Tests" "$tmp/Packages/B" "$tmp/Packages/C" "$tmp/Packages/D/Tests"
touch "$tmp/Packages/A/Package.swift" "$tmp/Packages/B/Package.swift" "$tmp/Packages/D/Package.swift"
assert_eq "lists packages with tests, sorted" '["A","D"]' "$(bash "$SCRIPTS/list-packages.sh" "$tmp")"
rm -rf "$tmp/Packages/A" "$tmp/Packages/D"
assert_eq "empty array when none" '[]' "$(bash "$SCRIPTS/list-packages.sh" "$tmp")"
finish
