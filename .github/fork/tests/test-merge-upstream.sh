#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
s="$SCRIPTS/merge-upstream.sh"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
g() { git -c init.defaultBranch=main "$@"; }

# upstream: v1 with app + an upstream workflow; fork: deletes upstream workflows, adds its own
setup() {
  rm -rf "$root/up" "$root/fork"
  g init -q "$root/up"; cd "$root/up"
  mkdir -p .github/workflows src
  printf 'a\nb\nc\n' > src/app.txt; echo up > .github/workflows/release.yml
  g add -A; g commit -qm v1; g tag v1
  g clone -q "$root/up" "$root/fork"; cd "$root/fork"
  g rm -q .github/workflows/release.yml; mkdir -p .github/workflows .github/fork
  echo ours > .github/workflows/fork-ci.yml; echo ours > .github/fork/x.sh
  printf 'a\nb\nc\nextras\n' > src/app.txt
  g add -A; g commit -qm fork
}
upstream_commit() { # message, then a command run in the upstream repo
  (cd "$root/up" && eval "$2" && g add -A && g commit -qm "$1" && g tag "$1")
  (cd "$root/fork" && g fetch -q origin --tags)
}

setup
upstream_commit v2 "printf 'A\nb\nc\n' > src/app.txt"
out=$(bash "$s" v2); rc=$?
assert_eq "clean merge exits 0" 0 "$rc"
assert_eq "clean merge commit message" "Merge upstream v2" "$(g log -1 --format=%s)"
assert_eq "clean merge has both changes" "$(printf 'A\nb\nc\nextras')" "$(cat src/app.txt)"
assert_eq "clean merge tree clean" "" "$(g status --porcelain)"

bash "$s" v2 >/dev/null; assert_eq "already merged exits 3" 3 "$?"

setup
upstream_commit v2 "printf 'a\nb\nc\nUPSTREAM\n' > src/app.txt"
before=$(g rev-parse HEAD)
out=$(bash "$s" v2); rc=$?
assert_eq "conflict exits 2" 2 "$rc"
assert_eq "conflict lists paths" "src/app.txt" "$out"
assert_eq "conflict leaves HEAD" "$before" "$(g rev-parse HEAD)"
assert_eq "conflict leaves clean tree" "" "$(g status --porcelain)"

setup
upstream_commit v2 "echo up2 > .github/workflows/release.yml; echo new > .github/workflows/new.yml; echo up > .github/workflows/fork-ci.yml; printf 'A\nb\nc\n' > src/app.txt"
bash "$s" v2 >/dev/null; rc=$?
assert_eq "workflow edits: merge exits 0" 0 "$rc"
assert_eq "workflow edits discarded" "fork-ci.yml" "$(ls .github/workflows | tr '\n' ' ' | sed 's/ $//')"
assert_eq "our workflow kept" "ours" "$(cat .github/workflows/fork-ci.yml)"
assert_eq "app change still merged" "A" "$(head -1 src/app.txt)"

setup
upstream_commit v2 "mkdir -p .github/fork; echo theirs > .github/fork/x.sh; echo t > .github/fork/y.sh"
bash "$s" v2 >/dev/null; rc=$?
assert_eq "fork dir edits: exits 0" 0 "$rc"
assert_eq "fork dir kept" "ours" "$(cat .github/fork/x.sh)"
assert_eq "fork dir no new files" "x.sh" "$(ls .github/fork)"

setup
bash "$s" nope >/dev/null 2>&1; assert_eq "unknown ref exits 1" 1 "$?"
finish
