# Settings and onboarding verification

Implementation is split into six commits: data availability, robot forehead status,
permission-first onboarding, optional cost settings, data/sync diagnostics, and
final regression verification.

## Expected states

| Configuration / event | Activity | Repository changes |
| --- | --- | --- |
| No home grant and no folders | Await access, never synthetic zero/demo | Unconfigured |
| Home grant only, readable supported logs | Read activity | Unconfigured |
| Development folders only | Read any accessible logs; otherwise await home access | Read selected folders |
| Both configured | Read activity | Read selected folders |
| Expired grant | Await renewed access; preserve historical records | Report access requirement independently |
| Read failure or stale scan | Do not report current quiet activity | Preserve previously stored records |
| Readable sources with a confirmed empty activity observation | Actual no-activity state | Independent repository state |
| Activity amount not queried | Source availability, no claim of zero activity | Independent repository state |
| Periodic scan with a recent successful read | Keep the last current state | No layout or state flicker |

A home-folder grant does not select every repository in home. Repository discovery
uses configured roots only. API keys and fixed subscriptions are optional and do
not gate local log ingestion. Removing a subscription clears its declared fee
without disabling activity configuration. Demonstration remains available behind
an explicit launch argument; missing configuration never starts it automatically.

## Automated checks

- Complete local Swift tests: 392 executed, 4 skipped, 0 failures.
- Permission/availability matrix, missing repositories, scanner freshness and
  historical source availability are covered by LocalDataStatusTests.
- OptionalCostConfigurationTests cover clearing fees and distinguishing connection
  failures from rejected credentials.
- CloudSyncAvailabilityTests verify Debug status checks do not create cloud writes.
- macOS Debug build and unsigned Release build pass.

## Actual desktop checks

- Robot dashboard opens with its fixed shape and current intensity.
- Settings sidebar contains repository, developer-tool, optional account/cost,
  and data/sync destinations. Demo controls are absent by default.
- New welcome, access and completion pages fit the window; existing home grant
  and development folders are retained during rerun.
- Data/sync page displays the actual Debug database path and explicitly disabled
  Debug cloud access/writes.

## Remaining platform acceptance

- Fresh sandbox profiles with denied grants, revoked grants and renewed grants
  still need native permission-dialog acceptance. The state decisions are covered
  automatically; existing user grants were not revoked during verification.
- A real signed Release iCloud round trip is not verified by an unsigned build.
- Newly added copy provides Chinese and English; other selected languages use the
  English fallback, matching the current robot dashboard copy strategy.
- Existing user localization edits and untracked design previews are excluded from
  the implementation commits.
