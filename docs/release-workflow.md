# AI Pulse Release Workflow

This document defines the release flow for `wxy/ai-pulse-macos`.

## 1. Cut and prepare the release

- Ensure all release changes are merged into `main`.
- Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in:
  - `AIPulse/AIPulse.xcodeproj/project.pbxproj`
  - `Suites/AIPulse_Suites.xcodeproj/project.pbxproj`
- Update the macOS and iOS App Store copy under `docs/`.
- Run the full verification suite before tagging:
  - `make test`
  - macOS build
  - iOS build
  - watchOS build

## 2. Create a draft GitHub Release

Push a `vX.Y.Z` tag to `main`:

```bash
git tag -a v1.2.6 -m "v1.2.6"
git push origin v1.2.6
```

The `.github/workflows/release.yml` workflow will create a **draft** GitHub
Release, not a public release.

Edit the draft release notes using the global
`github-release-announcement` standard. It produces release notes and a
structured `Store Copy Handoff` section, but does not write final App Store
copy.

## 3. Generate App Store submission copy

Use the approved draft release's `Store Copy Handoff` metadata as input for
`appilot`, then use appilot's output to update the App Store copy. After that,
submit the macOS and iOS builds to App Store Connect.

## 4. Promote the draft after App Store approval

Only after App Store review has passed:

```bash
make publish-release VERSION=1.2.6
```

This runs:

```bash
gh release edit v1.2.6 --draft=false
```

The GitHub Release becomes publicly visible at that point.
