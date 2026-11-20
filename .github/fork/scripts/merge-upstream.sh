#!/usr/bin/env bash
# Merges an upstream ref (normally a release tag) into the current branch.
# The fork owns .github/workflows and .github/fork: whatever upstream did there is discarded,
# so those paths can never conflict and the merge never carries workflow edits.
#
# Usage: merge-upstream.sh <ref>
# Exit:  0 merged (commit "Merge upstream <ref>")
#        3 <ref> is already part of HEAD, nothing to do
#        2 conflicts: conflicted paths on stdout, merge aborted, tree left as it was
#        1 any other error (unknown ref, dirty tree)
set -uo pipefail
ref="${1:?usage: merge-upstream.sh <ref>}"
OWNED=(.github/workflows .github/fork)

git rev-parse -q --verify "${ref}^{commit}" >/dev/null || { echo "unknown ref: $ref" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }
if git merge-base --is-ancestor "$ref" HEAD; then
  echo "$ref is already merged" >&2
  exit 3
fi

git merge --no-ff --no-commit "$ref" >/dev/null 2>&1
# Drop everything upstream left under the fork-owned paths that HEAD doesn't have (added files,
# modify/delete conflicts on files the fork deleted), then put the rest back exactly as on HEAD.
git ls-files --cached -- "${OWNED[@]}" | sort -u | while IFS= read -r f; do
  if ! git cat-file -e "HEAD:$f" 2>/dev/null; then
    git rm -q --cached -f -- "$f" >/dev/null 2>&1 || true
    rm -f -- "$f"
  fi
done
for p in "${OWNED[@]}"; do
  if git cat-file -e "HEAD:$p" 2>/dev/null; then
    git restore --source=HEAD --staged --worktree -- "$p"
  fi
done
git clean -fdq -- "${OWNED[@]}"

conflicts=$(git diff --name-only --diff-filter=U)
if [ -n "$conflicts" ]; then
  echo "$conflicts"
  git merge --abort
  exit 2
fi
git commit -q --no-edit -m "Merge upstream $ref" || { git merge --abort; echo "commit failed" >&2; exit 1; }
