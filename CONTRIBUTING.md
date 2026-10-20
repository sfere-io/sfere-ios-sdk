# Contributing to sfere-io/sfere-ios-sdk

## Ground rules

- Everything lands on `main` through a pull request. Direct pushes, force-pushes,
  and branch deletion are blocked by repository rulesets — including for admins.
- Follow [CLAUDE.md](CLAUDE.md) for the rules the code follows (wire shape, event
  names, no hashing, no third-party hosts, no vendor names) and the parity rules
  with the Android SDK.
- Secrets never enter the repository. Staging keys go in the git-ignored `.env`;
  tests use write keys starting with `sferetest`.

## Local setup

A Mac with Xcode 26, XcodeGen for the sample app (`brew install xcodegen`) and
SwiftLint (`brew install swiftlint`). Then, once per clone:

```sh
git config core.hooksPath .githooks
```

The pre-commit hook formats the staged Swift with swift-format, regenerates the
public API dump when the SDK sources are staged, and refuses a commit that names the
ingestion vendor. `git commit --no-verify` is the escape hatch; CI is the real gate.

## Pull request policy

Enforced by the `protect-main` ruleset on `main`:

| Rule | Setting |
|---|---|
| Pull request required | Yes |
| Approving reviews | 1 |
| Code owner review | Required for paths listed in `.github/CODEOWNERS` |
| Stale approvals | Dismissed when new commits are pushed |
| Last push approval | The most recent push must be approved by someone else |
| Review threads | All resolved before merge |
| Merge method | Squash only (linear history required) |
| Required checks | `Swift style`, `Static analysis`, `API contract`, `Tests & coverage`, `SonarQube`, `Build` |
| Branch up to date | Yes (strict checks) |
| Bypass | None — the rules apply to admins too |

Sensitive paths (`.github/`, `.githooks/`, `Package.swift`, `Package.resolved`,
`Support.swift` (the version), the privacy manifest, `api/`, `fixtures/`, the lint and
Sonar configs, the policy docs) require approval from an SDK maintainer (@mabumusa1
or @KaramYaaqba).

What the checks gate, and how to run them locally, is in [docs/ci-cd.md](docs/ci-cd.md).

## Review expectations

- Review the diff, not the description. If you didn't read it, don't approve it.
- A change to what the SDK sends is done when the Android SDK has the matching
  change and `tools/parity.sh` reports every event as "same".
- A public API change shows up as a diff of `api/SfereAnalytics.api` (CI puts it in
  the "API contract" job summary). Read it as the contract it is.
- Keep PRs small and focused; large PRs get rubber-stamped.

## Versions, CHANGELOG and releases

- `SfereVersion.current` in `Sources/SfereAnalytics/Support.swift` is the SDK version.
  A version that has a `v<version>` tag is released and immutable: apps resolve the
  package from that tag. Bump the version before changing the SDK again. CI fails a PR
  that changes the SDK under a tagged version.
- Every SDK change adds an entry under `## [Unreleased]` in `CHANGELOG.md`
  (label the PR `skip-changelog` for changes that don't affect the package).
- Releasing: see [docs/ci-cd.md](docs/ci-cd.md#releasing). In short: rename
  `[Unreleased]` to the version with the date, merge, then an admin tags
  `v<version>` on `main`. The `release` workflow resolves and builds the tag the way
  an app does and creates the GitHub release.

## Merge flow

1. Open the PR against `main` (the template will guide you).
2. Wait for the required checks to pass.
3. Get one approval (plus a maintainer for sensitive paths).
4. Squash-merge. The branch is deleted automatically.

## Hotfix / emergency bypass

If `main` is broken and the rules block an urgent fix:

1. One of the maintainers edits or deactivates the `protect-main` ruleset.
2. The fix lands (still prefer a PR).
3. The ruleset is restored immediately afterwards.
4. The bypass is recorded in the PR or commit message with the reason
   (`hotfix: <what> — ruleset bypass approved by <who>`), and reviewed
   post-merge within one working day.

Silent bypasses are not acceptable: a bypass without a recorded reason is
treated as an incident.

## Updating this policy

Changes to `.github/CODEOWNERS`, this file, or the rulesets themselves are
sensitive-path changes: they need a maintainer's approval and should be made in
a PR (except in the emergency flow above).
