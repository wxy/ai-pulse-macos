# Symbolic-link access and signed sandbox verification

## Failure modes identified before implementation

- A saved bookmark fails to resolve, activate, refresh, or persist; success must not be reported.
- A logical root, an ancestor, a nested linked directory, or a linked log file points outside the granted scope.
- Metadata is readable but enumerating a directory / reading Git HEAD / reading a log file is denied.
- A genuine empty directory must remain distinguishable from a failed or incomplete scan, including cached counts and summaries.
- Optional logs are absent, a configured root disappears, a link breaks, or a volume disconnects; avoid authorization loops for missing resources.
- Permission is denied after some repositories were found; keep the partial result explicitly incomplete.
- The user cancels the panel or chooses a directory that does not cover the current target; retain the pending issue.
- An alias changes target before / during / after granting access; never treat the previous target's grant as permission for its replacement.
- A valid bookmark survives app restart; an invalid old bookmark must be replaceable without deleting history or changing the logical configured root.
- Granting a parent of the actual target covers it; unrelated / sibling directories remain outside that grant.
- Git errors retain operation, native error code and native detail instead of Swift's generic error 0.
- Recovery clears only relevant failures and triggers repository / log re-reading without duplicate log facts.

## Validation plan

Use a separate signed, sandboxed Debug QA bundle and synthetic filesystem / Git / Codex inputs on the external volume in an ignored test directory. No production preference, bookmark, database, or raw conversation is modified. Exercise the same directory picker, scan cache, symlink walker and Codex ingest implementation as the app. Validate deny → cancel → grant → read → restart → retarget, and nested targets. Record exact commands and actual results below; remove all test inputs, logs and build products after reporting.

## Results

Environment: macOS 26.6.2 (25G83), Xcode 27.1 (27A9275), arm64. Inputs were on the MacSSD volume in the ignored `.build/sandbox-access-fixtures` directory of the isolated worktree. The separately signed bundle was `xingyu.wang.aipulse.accessqa`; its container, defaults and SQLite database were separate from the user's normal Debug and Release profiles.

The full macOS application target was compiled, then its QA copy was signed with the existing Developer ID Application certificate. Verified entitlements were App Sandbox, user-selected read-only files, and app-scoped bookmarks. This was an actual sandbox process and actual system `NSOpenPanel` interaction, not an injected permission predicate or an unsigned SwiftPM substitute. The QA runner uses the production grant UI, `RepoScanCache`, `SymlinkFileTree`, `LogWatcher`, SQLite persistence and `GitRepo`. It disables normal account/cloud/timer startup by entering only in the dedicated Debug QA bundle. The copy's widget plugin was removed before signing/launch so no signed test widget was registered.

| Scenario | Observed result |
| --- | --- |
| No grants | Repository count unavailable; Codex rows 0; two permission issues with real paths. |
| Grant synthetic home | 1 repository, 1 Git commit, 1 Codex row / 15 tokens; no issues. |
| Move development and sessions folders outside granted home; leave original links | Both moved folders retained their inode in this same-volume move. Real target reads were denied; count unavailable; the existing Codex row remained intact. Both real targets were offered for authorization. |
| Cancel picker | Pending issues and history retained; no success or zero-repository result. |
| Grant moved A targets | 1 repository and Git commit; same 1 Codex row / 15 tokens; no duplicate facts or issues. Logical configured root unchanged. |
| Append Codex event, restart | Bookmarks restored without another picker; 1 repository, 2 Codex rows / 30 tokens; no issues. |
| Retarget both aliases to ungranted B folders | A grants did not cover B; count unavailable, historical 2 rows / 30 tokens retained; B paths offered. |
| Choose unrelated folder | Target validation alert; pending issues unchanged. |
| Grant B folders | 1 repository and Git commit, 3 Codex rows / 60 tokens; no issues. |
| Add relative nested development link and nested Codex day link outside B grants | Partial repository result was unavailable, with both exact nested targets identified. |
| Grant nested targets | 2 repositories, 4 Codex rows / 66 tokens; no issues. |
| Point development alias at authorized empty folder | A valid complete count of 0; no issues. |
| Break configured link | Count unavailable; folder-unavailable message with Retry rather than an authorization loop. Existing log history retained. |
| Inject invalid old logical bookmark; retarget development to ungranted C | Real native error: `Git HEAD (-1): could not open .../.git/HEAD: Operation not permitted`; no generic error 0. |
| Grant C | 2 repositories; Git read successful; old `Bookmark.develop` failure cleared. Only the unrelated file-link failure remained. |
| Link one Codex JSONL file to a separate ungranted folder | Logical file and actual target shown; picker opened the real parent folder. Granting that folder produced 5 Codex rows / 78 tokens, 2 repositories, 1 Git commit; permission issues and ingest errors both 0. |
| Restart after all grants | Same 2 repositories, 5 Codex rows / 78 tokens, 1 Git commit, 0 issues / ingest errors. |

Existing regression suite: 527 tests, 523 passed, 4 conditionally skipped, 0 failures. The skipped tests require an explicitly provided real repository, Codex journal, compressed DSH journal, or SQLite backup; no private inputs were supplied. After the final log-error/UI changes, the affected suites ran 49 tests (48 passed, 1 real-repository check skipped, 0 failures). The final scan-target identity adjustment ran the 12 cache/symlink tests, all passed. Localization validation passed: 775 active keys, 10 locales, 416 inline pairs. `git diff --check` passed.

### Reproduction

Use a disposable worktree and an ignored test directory. For the run above, `ACCESS_QA_TMP=/private/tmp/aipulse-access-qa`; all builds and full logs were temporary.

```sh
swift test --scratch-path "$ACCESS_QA_TMP/swift" --jobs 4
swift test --scratch-path "$ACCESS_QA_TMP/swift" --jobs 4 --filter 'RepoScanCache|LocalDataStatus|RepositoryScope|Aider|Symlink|GitRepo|LogWatcher'
swift test --scratch-path "$ACCESS_QA_TMP/swift" --jobs 4 --filter 'RepoScanCache|Symlink'
xcodebuild -workspace AIPulse.xcworkspace -scheme AIPulse_macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ACCESS_QA_TMP/DerivedData" CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=xingyu.wang.aipulse.accessqa build
python3 scripts/check-localizations.py
git diff --check
```

Generate the initial synthetic inputs from the worktree root (no existing test directory):

```python
from pathlib import Path
import datetime, json, subprocess
base = Path('.build/sandbox-access-fixtures').resolve()
assert not base.exists()
home = base / 'home'
(home / '.codex/sessions/2026/10/23').mkdir(parents=True)
(base / 'entry-home').symlink_to(home, target_is_directory=True)
(home / 'empty').mkdir()
for root in (home / 'develop/demo', base / 'targets/develop-b/demo-b',
             base / 'targets/nested-repo/extra'):
    root.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    (root / 'README.md').write_text('Synthetic access QA repository\n')
    subprocess.run(['git', '-C', str(root), 'add', 'README.md'], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Access QA',
                    '-c', 'user.email=qa@example.invalid', 'commit', '-qm',
                    'Synthetic QA input'], check=True)
def log(path, sid, tokens):
    path.parent.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    records = [dict(type='session_meta', payload=dict(session_id=sid, model='gpt-5-codex')),
               dict(timestamp=timestamp, type='token_count', payload=dict(
                   last_token_usage=dict(input_tokens=tokens, output_tokens=tokens // 2)))]
    path.write_text(''.join(json.dumps(r) + '\n' for r in records))
log(home / '.codex/sessions/2026/10/23/rollout-initial.jsonl', 'sandbox-a', 10)
log(base / 'targets/sessions-b/2026/10/23/rollout-new.jsonl', 'sandbox-b', 20)
log(base / 'targets/log-day/rollout-nested.jsonl', 'sandbox-c', 4)
```

Copy `DerivedData/Build/Products/Debug/AIPulseDebug.app` to `AIPulseAccessQA.app` inside the temporary task directory. Remove the copy's `Contents/PlugIns` before signing. Sign the copy and its embedded libraries with the existing local Developer ID identity and a QA entitlements plist containing only these Boolean keys:

```xml
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.files.user-selected.read-only</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
</dict>
```

```sh
codesign --force --deep --sign "$ACCESS_QA_SIGNING_ID" \
  --entitlements "$ACCESS_QA_TMP/qa.entitlements" "$ACCESS_QA_TMP/AIPulseAccessQA.app"
codesign --verify --deep --strict "$ACCESS_QA_TMP/AIPulseAccessQA.app"
open -n "$ACCESS_QA_TMP/AIPulseAccessQA.app" --args \
  -AccessQAHome "$ACCESS_QA_WT/.build/sandbox-access-fixtures/entry-home" \
  -AccessQARoot "$ACCESS_QA_WT/.build/sandbox-access-fixtures/entry-home/develop"
```

Use Authorize fixture home once for the synthetic home only. Rename `home/develop` to `targets/develop-a` and `home/.codex/sessions` to `targets/sessions-a`, leave symlinks in their original locations, and use Scan. Exercise cancel, then real-target grants. Append a second 10-input/5-output event to the original JSONL before restarting. Retarget aliases to B and repeat grants; use an unrelated `home/empty` selection to exercise validation. Add `targets/develop-b/team -> ../nested-repo` and `targets/sessions-b/2026/10/23/borrowed -> targets/log-day` (absolute destination for the latter). After nested grants, temporarily retarget development to `home/empty`, then an absent path, then restore it. For C, copy development B preserving links and retarget the original alias. Launch once with `-AccessQAInvalidBookmark YES -AccessQAGitRepo <logical-development>/demo-b` to reproduce the invalid legacy bookmark and native HEAD error. Add a file alias to another synthetic journal with 8 input/4 output tokens in `targets/log-file`; grant its real parent folder. Restart without injection arguments and check the final result above.

## Scope and cleanup

These results establish signed App Sandbox reading and bookmark recovery with synthetic Git/Codex inputs on MacSSD. They do not establish acceptance of the user's private production history, Mac App Store distribution, FSEvents delivery, physical volume unplug/remount, simultaneous target changes during a picker, or long-running performance; iOS/watchOS were not exercised. A single blocked filesystem call remains outside the soft deadline's ability to preempt. The same-volume inode observation above describes the parent-grant boundary in this fixture, not an undocumented guarantee about bookmark internals.

Final source was rebuilt, re-signed with Developer ID and restarted after the final changes: 2 repositories, 5 Codex rows / 78 tokens, 1 Git commit, 0 directory-access issues, 0 ingest errors. The final cache/symlink regression rerun passed all 12 tests.

Cleanup completed: stopped and unregistered the exact temporary QA app; removed its container Data (test database/WAL, preference/bookmark data, caches and logs), the ignored synthetic input directory, the temporary app, DerivedData, SwiftPM scratch and full captured logs. The QA copy contained no signed widget extension. macOS-managed empty container metadata outside Data was left to the OS. Normal Debug/Release profiles were not changed. Only this report and the Debug-only acceptance runner are retained in source; no process artifacts were staged.
