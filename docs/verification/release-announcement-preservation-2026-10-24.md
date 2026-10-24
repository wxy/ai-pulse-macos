# Release announcement preservation — 2026-10-24

## Scope and failure modes (defined before implementation)

The v2.0.2 tag run used a fixed title/body and `draft: true`, replacing an existing announcement and its publication state. The replacement workflow uses a Python entry point that can list releases and create a draft; it has no PATCH/PUT/DELETE path. Existing drafts and public releases, including empty bodies, remain unchanged. Only absent releases read the tagged commit's RELEASE_DRAFT.md and create a draft from the exact UTF-8 body and first H1 title.

1. Existing draft or published release: preserve the entire object, title/body/state/assets; repeated invocation makes no mutation, even when local notes are missing.
2. Matching release on a later page; published-tag lookup may omit drafts. Traverse authenticated release-list pages before deciding a release is absent.
3. No release: create exactly one draft from UTF-8 RELEASE_DRAFT.md, including exact bilingual body, first H1 title, requested tag and event SHA; never generate replacement notes or publish automatically.
4. Missing, empty, invalid UTF-8, missing heading, or wrong-version notes: fail before POST.
5. Missing token/repository/tag/SHA, invalid context, or malformed token: fail before contacting API, without disclosing the token.
6. Lookup auth/permission/not-found/rate-limit/server failures, invalid JSON or release-list schema, redirects, timeouts/network failures: fail closed, never POST or follow redirects.
7. Create rejection, invalid response, server failure or lost response: fail without PATCH or retry; a future run rechecks existing state first.
8. Creation race returns 422: re-list and preserve the now-existing draft/published release; without a matching release, report failure.
9. A lost create response can leave a real draft; subsequent invocation must find and preserve it instead of creating another.
10. Workflow must serialize same-tag jobs without cancelling active work, retain tag-only triggering, use event context via environment variables, and run the actual checked-in script. Existing releases are never edited or downgraded.

Method: run the actual release script as a subprocess against a local authenticated HTTP fixture. This boundary is necessary to force permission failures, races and lost responses without editing real GitHub releases. No isolated unit tests are added. Fixture source/inputs/logs live only in this task temporary directory and are deleted after the report is recorded.

## Environment and method

macOS 26.6.2; Python 3.14.6. The failure matrix and temporary process-level HTTP fixture were written before the implementation. The initial red check stopped at the missing implementation entry point. The first HTTP attempt exposed a fixture method named `request` colliding with BaseHTTPRequestHandler's socket attribute; renaming that fixture method resolved it. No implementation change was needed for that fixture error. Final review then identified that a malformed token could appear in a low-level client exception. A new process-level scenario reproduced that leak before changing the implementation. The script now prints controlled errors or exception type names only; the complete final 51-case run passed after that fix.

The final run executed the checked-in Python entry point as a fresh subprocess for each case, with an empty temporary working directory and controlled GITHUB_* environment. A ThreadingHTTPServer bound to 127.0.0.1 recorded all API requests and simulated GitHub release state. It required Bearer fixture authentication, and returned the normal GitHub list/create JSON shape. The fixture substitutes only the external HTTP service: context validation, note loading, JSON encoding, pagination, timeouts, redirects, conflict handling and process exits all used production code.

GitHub service failures, creation races and lost responses cannot reliably be forced on the real repository without changing releases, so these cases use that local API boundary. No real release was created, edited, published, deleted or retagged by this verification. A separate read-only check confirmed the current v2.0.2 draft appears in the release list while the tag endpoint returns 404, which is why the implementation lists authenticated releases rather than treating that endpoint's 404 as absence.

## Results

**51 scenarios passed.** Every case prohibited PATCH/PUT/DELETE; existing full release objects (including title, body, draft flag, target, prerelease flag and assets) were compared before/after. The fixture returned its fake token inside HTTP error bodies to verify that diagnostics do not leak it. A shell-like string in the notes remained literal and created no file.

| Cases | Inputs and actual result |
| --- | --- |
| New draft and repeat | Exact English/Chinese body, first H1, v2.0.2 and event SHA sent in one POST; draft=true, prerelease=false, generate_release_notes=false. Repeat made no second POST. |
| Existing draft/public (8 variants) | Present, absent, empty or wrong-version local notes never changed the existing release or caused a POST. |
| Pagination (3) | 100 unrelated releases followed by a matching draft/public release were preserved; a genuinely empty second page permitted one new draft. |
| Invalid notes (7) | Missing, empty, whitespace, invalid UTF-8, missing H1, wrong version and misleading version prefix failed before POST. |
| Context (10) | Empty token/repository/tag/SHA; invalid repository/tag/ref type/SHA/API URL and malformed Authorization token failed before any HTTP request, without logging the token. |
| Lookup errors (13) | HTTP 401/403/404/429/500/503; invalid JSON; four invalid list/item schemas; redirect; refused connection. All failed without POST; redirect was not followed. |
| Creation races (2) | HTTP 422 with a newly present draft/public release triggered a recheck and preserved the winner. |
| Create errors (5) | HTTP 403/422-without-existing/500, invalid JSON and invalid create schema failed without editing or automatically retrying. |
| Timeouts (2) | A 31-second lookup response caused the 30-second client timeout without POST. A delayed response after successful creation failed once; a subsequent invocation found the saved draft without a second POST. |

Python compilation, all workflow YAML syntax parsing and git diff --check passed. Workflow wiring was statically checked for tag-only trigger, environment token, checked-in script entry, contents:write permission, a same-tag concurrency group, cancel-in-progress=false and absence of the old release action/fixed-body settings.

No macOS/iOS build was run: this change affects release automation and documentation, with no app source, dependency, target or version-setting change. Existing GitHub CI runs independently on the PR. No hosted tag-push run, GITHUB_TOKEN permission acceptance, network performance, Archive, App Store or client runtime acceptance is claimed. Do not rerun the obsolete v2.0.2 tag job; future tags must include the corrected workflow commit. The existing v2.0.2 tag remains unchanged.

## Reproduction

Create an independent directory under TMPDIR. Generate RELEASE_DRAFT.md with first line `# AI Pulse 2.0.2 — Release recovery`, English and Chinese text, trailing newlines and a literal `$(touch SHOULD_NOT_EXIST)` line. Run a local HTTP fixture at `/repos/example/project/releases` with the table's states/statuses; return up to 100 releases per page. Existing fixtures use tag_name=v2.0.2, an arbitrary hand-edited title/body, draft=true or false, an asset and an unrelated target. For pagination prepend 100 objects with other tags. For a create conflict, insert the winner before replying 422. For an uncertain create, persist the requested draft before delaying its response 31 seconds, then retry the command with the delay removed. Compare all original objects and POST counts, reject any edit method and ensure process output does not contain the fixture token.

Run the actual entry point from the input directory with:

```sh
GITHUB_TOKEN=fixture-token GITHUB_REPOSITORY=example/project \
GITHUB_REF_NAME=v2.0.2 GITHUB_REF_TYPE=tag \
GITHUB_SHA=1111111111111111111111111111111111111111 \
GITHUB_API_URL=http://127.0.0.1:FIXTURE_PORT \
python3 /path/to/checkout/scripts/create-release-draft.py

PYTHONPYCACHEPREFIX="$qa_dir/pycache" python3 -m py_compile \
  scripts/create-release-draft.py scripts/generate-icons.py scripts/check-localizations.py
ruby -e 'require "yaml"; Dir[".github/workflows/*.yml"].each { |f| YAML.parse_file(f) }'
git diff --check
```

Actual temporary harness command: `python3 $qa_dir/check_release_flow.py /path/to/checkout/scripts/create-release-draft.py`.

Source script SHA-256: `0d2e87194a08d661c740e29b52f7d02b7e082a07265ea7a043e027b61ba0a123`. Temporary fixture SHA-256: `4a368aef5146e5ff83ea98d077119431ddd7988422f020f552ca8b2617f42901`.

## Scope protection and retention

The bilingual announcement now separates macOS, iOS/Apple Watch and shared-contract changes, explicitly identifying unchanged platforms. Existing macOS 2.0.2 (34), companion 2.0.1 (33), and shared payload 2.0.0 settings remain unchanged.

The unrelated local Sources/Localizable.xcstrings and Suites/iOS/Info.plist edits remain outside the PR, with SHA-256 values `1b4f038a9f61060c3a2def374a46b500ba3924952a5693f6583a491164c38a42` and `9e8fbb24153d9f696674801ae1a1d37fe3683ae36e423bac274b2941bba0cb10` respectively.

Only this report is retained as verification material. The temporary harness, HTTP state, inputs, output, log and Python bytecode cache are removed after results are recorded and before delivery; none enters Git.
