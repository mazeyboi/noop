# About this fork

`mazeyboi/noop` is a personal fork of [ryanbr/noop](https://github.com/ryanbr/noop) for one
iPhone. It adds a food log ("extras") in `Packages/NOOPExtras` with its own database, and
otherwise stays identical to upstream NOOP. Licence: PolyForm Noncommercial 1.0.0, as upstream
(see `LICENSE` and `NOTICE`). Personal, non-commercial use only.

## Releases

- `main` = the latest **upstream release tag** + this fork's commits.
- Every day `sync-upstream.yml` checks `ryanbr/noop` for a new release. If there is one it merges
  it, runs every package's tests, builds the unsigned iOS IPA with upstream's build steps and
  publishes `v<version>-extras.<N>` with `NOOP-ios-extras-<tag>.ipa` and its `.sha256`.
  On a merge conflict or any failure nothing is published and an issue is opened here.
- `N` starts at 0 for each upstream version and goes up by one per fork release.
- The IPA keeps the production bundle ID `com.noopapp.noop`, so it replaces the official app and
  keeps its data.

## Manual build

Actions → **Build and release** → Run workflow. With *publish* off you get the IPA as a build
artifact only. *Publish* is only accepted for the current `main`.

## What upstream files this fork changes

See `EXTRAS_PATCHES.md`.
