#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
s="$SCRIPTS/next-extras-tag.sh"
assert_eq "first release of a base is .0" "v12.0.0-extras.0" "$(printf '' | bash "$s" 12.0.0)"
assert_eq "max N + 1, ignores other tags" "v12.0.0-extras.4" \
  "$(printf 'v12.0.0-extras.0\nv12.0.0-extras.3\nv11.8.0-extras.9\nv12.0.0\ntesting-latest\n' | bash "$s" 12.0.0)"
assert_eq "numeric not lexical" "v12.0.0-extras.11" \
  "$(printf 'v12.0.0-extras.9\nv12.0.0-extras.10\n' | bash "$s" 12.0.0)"
assert_eq "other base resets to .0" "v12.1.0-extras.0" "$(printf 'v12.0.0-extras.2\n' | bash "$s" 12.1.0)"
assert_eq "dots in base are literal" "v12.1.0-extras.0" "$(printf 'v12x1x0-extras.5\n' | bash "$s" 12.1.0)"
printf '' | bash "$s" >/dev/null 2>&1; assert_eq "missing base exits 2" "2" "$?"
printf '' | bash "$s" 12.0 >/dev/null 2>&1; assert_eq "non-semver base exits 2" "2" "$?"
finish
