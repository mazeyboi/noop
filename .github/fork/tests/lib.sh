# Tiny assertion helpers shared by the fork's script tests.
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s: %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
finish() { [ "$FAILS" -eq 0 ]; }
