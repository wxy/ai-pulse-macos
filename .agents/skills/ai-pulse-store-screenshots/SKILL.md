---
name: ai-pulse-store-screenshots
description: Capture, recapture, and audit localized App Store screenshots for AI Pulse on iPhone, iPad, Apple Watch, and macOS. Use for screenshot planning, simulator preparation, language switching, deterministic naming, black-background macOS window capture, privacy review, or selective recapture after UI fixes in this repository.
---

# AI Pulse Store Screenshots

Produce truthful, repeatable screenshot assets from the current signed build while preserving the user's simulator data and unrelated work.

## Start from the approved matrix

Read [references/capture-matrix.md](references/capture-matrix.md) before capturing or auditing. Treat it as the current AI Pulse 2.0 baseline; a newer explicit user request overrides it.

Before acting:

- Inspect the worktree and active branch. Do not stage screenshot artifacts unless the user explicitly requests it.
- Confirm which platforms, locales, and screens are in scope. Recapture only affected files after a localized fix.
- Reuse the user's existing simulators and data. Do not erase devices, create isolated clones, or download large runtimes unless requested.
- Build the latest source before final capture. Reuse the established task-specific DerivedData when practical; do not create duplicate signed WidgetKit registrations.
- Keep real, staged, demo, derived, and unavailable data distinct. Never describe demo or injected data as real.

## Prepare each capture

1. Launch the latest signed app build and verify that its localized strings match the source. A successful build alone does not prove the running process is current; restart stale processes.
2. Select the approved time range and destination screen.
3. Verify the page has representative data, the correct locale, and no loading or expired-observation state.
4. Inspect privacy before capture:
   - Keep API keys masked.
   - Avoid tool sessions that reveal prompts or private conversation titles.
   - Prefer the GitHub Copilot detail page used in the approved matrix when it contains only neutral session titles.
   - Notice visible usernames and repository paths and report them to the user; do not silently redact or fabricate UI.
5. When controlling UI, fetch fresh accessibility state after every action and derive the next target again. Accessibility indices and window IDs are ephemeral; never reuse values from an earlier run without re-reading state.

## Capture by platform

- iPhone and iPad: use Simulator screenshot output at the device's native pixel size. Capture the 30-day dashboard.
- Apple Watch: use the paired Watch Simulator at native size. Capture Today. If sync data is unavailable, diagnose the phone/watch bridge before changing product code; use staged data only with explicit user approval.
- macOS: capture the app window itself, not the whole desktop. Resolve the current window ID immediately before capture, then use `scripts/capture_macos_window.sh` to composite the irregular window and shadow over opaque black.

Do not include widgets or the menu bar in this baseline: they are too small and risk including unrelated desktop content.

## Handle defects discovered during capture

Treat screenshot review as product QA, but keep evidence and authorization separate:

- Classify the problem as localization, layout, stale build, data semantics, runtime integration, or capture technique.
- For a requested code fix, change only scoped files, add proportional tests, rebuild, and verify the corrected live UI.
- Do not infer that a stored credential is valid or observable. Show provider capability, credential rejection, connection failure, and a successful observation as separate states.
- After a fix, replace only screenshots whose visible result changed. Do not recapture the full set automatically.
- If the work is on an existing PR branch, commit only code, tests, and the skill itself; keep `artifacts/` untracked unless explicitly requested.

## Audit and hand off

Run:

```bash
python3 .agents/skills/ai-pulse-store-screenshots/scripts/audit_screenshots.py \
  artifacts/app-store-screenshots/2.0 \
  --contact-sheet-dir /private/tmp/ai-pulse-screenshot-qa
```

The audit verifies the exact matrix, dimensions, and opacity, then creates one contact sheet per screenshot type for visual review. Inspect those sheets for clipping, ellipses, stale strings, privacy leaks, and inconsistent data states.

Finish by:

- Restoring display language to Follow System and the dashboard to 30 days unless the user requests another state.
- Removing only task-owned temporary files.
- Reporting automated checks separately from visual acceptance.
- Linking the screenshot root and any updated PR; state clearly whether screenshots are tracked by Git.
