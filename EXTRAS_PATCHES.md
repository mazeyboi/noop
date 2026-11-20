# Fork patches to upstream files

This fork (`mazeyboi/noop`) adds its own code in places upstream never touches, so upstream
releases merge cleanly. This file lists **every upstream file the fork changes**, and why.
Keep it to 3 or fewer app files, each a small insertion.

| Upstream path | Change | Why |
|---|---|---|
| `.github/workflows/` | Upstream's workflows deleted; the fork owns this directory (and `.github/fork/`). Upstream edits here are discarded at merge time by `.github/fork/scripts/merge-upstream.sh`. | Upstream's release, AltStore, branch-pruning and i18n jobs make no sense in a fork, and GitHub's `GITHUB_TOKEN` may not push workflow edits. |

App files touched: **none yet**.
