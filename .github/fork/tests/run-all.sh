#!/usr/bin/env bash
# Runs every test-*.sh next to this file; exits non-zero if any fails.
set -u
cd "$(dirname "$0")"
rc=0
for t in test-*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
exit $rc
