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

Only two App Store archives are uploaded: the macOS archive embeds
`AIPulseMacWidgetExtension`, while the iOS archive embeds the iPhone widget and
the Watch app; the Watch app embeds its Watch widget extension.

## 2. Create a draft GitHub Release

Create the draft against `main` without publishing or pre-creating the tag:

```bash
gh release create v2.0.0 --draft --target main \
  --title "AI Pulse 2.0.0" --notes-file RELEASE_DRAFT.md
```

For this repository, creating the draft stores the `v2.0.0` tag name and
`main` target without creating the remote Git tag. The tag remains absent while
the release is a draft, so final documentation can still merge into `main`.
Draft notes remain editable, but the release must not be published before App
Store approval; verify the target again immediately before publication.

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
make publish-release VERSION=2.0.0
```

This runs:

```bash
gh release edit v2.0.0 --draft=false
```

The GitHub Release becomes publicly visible at that point.
