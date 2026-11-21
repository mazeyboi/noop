# Fork patches to upstream files

This fork (`mazeyboi/noop`) adds its own code in places upstream never touches, so upstream
releases merge cleanly. This file lists **every upstream file the fork changes**, and why.
Keep it to 3 or fewer app files, each a small insertion.

| Upstream path | Change | Why |
|---|---|---|
| `.github/workflows/` | Upstream's workflows deleted; the fork owns this directory (and `.github/fork/`). Upstream edits here are discarded at merge time by `.github/fork/scripts/merge-upstream.sh`. | Upstream's release, AltStore, branch-pruning and i18n jobs make no sense in a fork, and GitHub's `GITHUB_TOKEN` may not push workflow edits. |

| `project.yml` | `NOOPExtras` local package; `NOOPExtrasUI` product as a `NOOPiOS` dependency; `NSCameraUsageDescription` in the NOOPiOS Info properties. 8 added lines, each block marked `# fork:`. | Links the food log into the iOS app; the camera is needed for barcodes and meal photos. |
| `StrandiOS/App/RootTabView.swift` | `import NOOPExtrasUI`; `ExtrasMoreRow()` as the first row of More → Body. 2 lines. | The entry point to the food log. |
| `StrandiOS/App/StrandiOSApp.swift` | `import NOOPExtrasUI`; `ExtrasApp.shared.appBecameActive()` in the existing `.active` scenePhase branch. 2 lines. | Estimates waiting meal photos and syncs to the home server when the app comes to the foreground. |

App files touched: **3** (target met). Everything else lives in `Packages/NOOPExtras` and its own
database file (`Application Support/NOOPExtras/extras.sqlite`). NOOP's own database is only read.

If a merge conflicts in one of these files, re-apply the insertion by hand: each is marked `fork:`.
