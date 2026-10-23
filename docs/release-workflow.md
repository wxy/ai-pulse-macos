# AI Pulse Release Workflow

This document defines the release flow for `wxy/ai-pulse-macos`.

## 1. Cut and prepare the release

- Ensure all release changes are merged into `main`.
- Choose the platforms included in the release. Bump `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` only in their projects:
  - macOS app and Mac widget: `AIPulse/AIPulse.xcodeproj/project.pbxproj`
  - iOS app, Watch app, and their widgets: `Suites/AIPulse_Suites.xcodeproj/project.pbxproj`
- Keep each containing app and its bundled apps/extensions at matching versions
  and builds. Separate macOS and iOS releases may use different versions/builds.
  For 2.0.2, only macOS and the Mac widget move to 2.0.2 (34); the other clients
  stay at 2.0.1 (33), with CloudKit payload version 2.0.0 unchanged.
- Update `RELEASE_DRAFT.md` and the README with the included platforms, changes,
  actual verification, and pending acceptance. Generate App Store copy only for
  the platforms being submitted, using the handoff flow below.
- Verify the affected targets and behavior before tagging. Version-only changes
  require configuration and bundle-metadata checks plus the affected release
  build; run relevant tests and runtime paths when behavior changes. For a
  release spanning macOS, iOS, and watchOS, include those builds and the
  cross-platform acceptance they require.
- The release owner completes signed Archive and distribution acceptance before
  App Store submission; an unsigned local build does not establish that acceptance.

A release covering both platforms uses two App Store archives. A macOS-only
release uploads only its macOS archive. The macOS archive embeds
`AIPulseMacWidgetExtension`, while the iOS archive embeds the iPhone widget and
the Watch app; the Watch app embeds its Watch widget extension.

## 2. Create a draft GitHub Release

Create the draft against `main` without publishing or pre-creating the tag:

```bash
gh release create v2.0.2 --draft --target main \
  --title "AI Pulse 2.0.2 — Safer Collection and Scan Recovery" --notes-file RELEASE_DRAFT.md
```

For this repository, creating the draft stores the `v2.0.2` tag name and
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
submit the builds for the included platforms to App Store Connect. For the
macOS-only 2.0.2 release, the owner creates and uploads the macOS Archive after
the preparation PR merges; no iOS/Watch submission is required.

## 4. Promote the draft after App Store approval

Only after App Store review has passed:

```bash
make publish-release VERSION=2.0.2
```

This runs:

```bash
gh release edit v2.0.2 --draft=false
```

The GitHub Release becomes publicly visible at that point.
