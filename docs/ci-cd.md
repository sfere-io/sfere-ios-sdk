# CI/CD for the Sfere iOS SDK

How the code is protected on the way to `main`, and how a version reaches app
developers. The model is the one `sfere-io/apis` and `sfere-io/sfere-android-sdk` use,
translated to a Swift package: every pull request passes the same named checks, `main`
is protected by rulesets with no bypass, Dependabot keeps dependencies and actions
current, and a release is a tag that only an admin can create.

Swift Package Manager installs a package straight from its git tags; there is no
registry to upload to. So **pushing a `v*` tag is publishing**, and everything that
guards a release guards the tag.

## Workflows

All actions are **pinned by commit SHA** (the `# vX.Y.Z` comment says which
release), and the two container images by digest. Keep it that way when editing a
workflow; Dependabot bumps the action pins (images: see [Tool versions](#tool-versions)).
Every workflow declares `permissions: contents: read` at the top and widens it only
on the job that needs more.

### `ci.yml` — the quality gate

| Item | Value |
|---|---|
| Triggers | `pull_request` (opened, synchronize, reopened); `push` to `main`; `workflow_call` (from `release.yml`) |
| Runners | `macos-26` (Xcode 26) for **Build** and **Tests & coverage** only; Linux for the rest. macOS minutes cost ten times Linux minutes on a private repository |
| Concurrency | one run per ref; a newer push to a PR cancels the older run |

| Job (check name) | What it runs | Fails when |
|---|---|---|
| **Swift style** | `swift format lint --strict` over `Package.swift`, `Sources`, `Tests`, `Example`, in the `swift:6.4.1-noble` container | any file is not formatted the way `.swift-format` says (4 spaces, 140 columns). Fix: `swift format --in-place --recursive Package.swift Sources Tests Example` (or `xcrun swift-format …`), or let the pre-commit hook do it |
| **Static analysis** | `swiftlint lint --strict` in the `ghcr.io/realm/swiftlint:0.65.1` container | any SwiftLint finding (`.swiftlint.yml`, zero allowed, no baseline). Findings are annotated on the PR's diff |
| **Build** | `swift package resolve --force-resolved-versions`; `tools/api_dump.sh` (the SDK for the iOS Simulator, with the public API dump); the SDK for iOS devices in Release; the sample app and its UI tests (`build-for-testing`), generated with a pinned XcodeGen; a check of what an app gets | `Package.resolved` is out of date with `Package.swift`; an error, or a warning in this repository's code (`tools/xcodebuild_strict.sh`: the dependencies' warnings are not ours, and `SWIFT_TREAT_WARNINGS_AS_ERRORS` cannot be scoped to one package from a Swift 5.9 manifest); the sample app or the UI tests do not compile; the built app does not carry the SDK's `PrivacyInfo.xcprivacy` or it is not a valid plist. The dump is the `api-dump` artifact |
| **API contract** | after **Build**: vendor-name grep over every tracked file; the committed `api/SfereAnalytics.api` against Build's dump; on PRs the public API diff against the base goes into the job summary; the version and CHANGELOG rules | the ingestion vendor is named anywhere; the committed dump is stale (fix: `tools/api_dump.sh` on a Mac, the diff is in the summary); the SDK changed while `SfereVersion.current` is already tagged; the SDK changed without a `CHANGELOG.md` change (label `skip-changelog` to waive). "The SDK" is `Sources/`, `Package.swift` and `Package.resolved` |
| **Tests & coverage** | `swift test --enable-code-coverage --force-resolved-versions`, then `llvm-cov` to lcov and to SonarQube's generic coverage format | a test fails. The summary shows the XCTest result and the line coverage; the log and both reports are the `test-results` artifact |
| **SonarQube** | after **Tests & coverage**: `SonarSource/sonarqube-scan-action` with `sonar-project.properties` and the coverage from `test-results`, on Linux (Swift analysis needs no build) | the quality gate fails (`sonar.qualitygate.wait=true`). **Skipped with a note when `SONAR_TOKEN` is not set** (Dependabot runs), so the required check still passes |

A job that is skipped because the job it needs failed counts as passing for a
required check, so **API contract** relies on **Build** being required too (it is).

### Dependency graph

GitHub reads `Package.resolved` for the dependency graph itself, so Dependabot alerts
see the exact resolved versions with no submission workflow (the Android SDK needs
one because Gradle resolves at build time). GitHub's pull-request dependency-review
action is not used: on a private repository it needs GitHub Advanced Security, which
this plan does not include.

### `release.yml` — verify and release

| Item | Value |
|---|---|
| Trigger | `push` of a tag matching `v*` |
| Gate | the whole `ci.yml` first (`workflow_call`), so a release never ships code that did not pass every PR check |
| Environment | `release` (deployment record; accepts only `v*` refs) |
| Runner | `macos-26` |
| Permissions | `contents: write` (the GitHub release) on the release job only |

Steps, in order:

1. The tag is `vX.Y.Z` or `vX.Y.Z-pre.N`, equals `SfereVersion.current` in
   `Sources/SfereAnalytics/Support.swift`, points at a commit on `main`, and
   `CHANGELOG.md` has a `## [X.Y.Z]` section.
2. A throwaway app package depends on `https://github.com/sfere-io/sfere-ios-sdk.git`
   at `exact: "X.Y.Z"` and resolves it from GitHub, as an app does (the Actions token
   stands in for the developer's GitHub account during the beta). The resolved
   revision must be the tagged commit, and the package must build for the iOS
   Simulator.
3. `gh release create vX.Y.Z` with the CHANGELOG section as notes (plus the install
   snippet and the commit), the public API dump attached, and `--prerelease` when the
   version has a `-` suffix.

## Releasing

1. On a branch: make sure `SfereVersion.current` is the version to ship and is not
   tagged yet (CI enforces this on every SDK change). Rename `## [Unreleased]` in
   `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`, and add a new empty `## [Unreleased]`
   above it. Open the PR, get it merged.
2. An admin tags the merge commit on `main` and pushes the tag:

   ```sh
   git switch main && git pull
   git tag vX.Y.Z
   git -c credential.helper='!gh auth git-credential' push origin vX.Y.Z
   ```

   Only admins can create `v*` tags (the `release-tags` ruleset), and no one can
   move or delete a tag (`protect-tags`).
3. Watch the `release` run. When it is green, the release is at
   https://github.com/sfere-io/sfere-ios-sdk/releases.
4. The tag is public to every app with access the moment it is pushed. If a later
   step fails, fix forward with a new version, never by re-tagging.

Beta versions are `X.Y.Z-beta.N` (`0.1.0-beta.1` first). An app pins a beta with
`exact:`; `from:` ranges skip pre-releases. At 1.0.0 the repository becomes public and
apps add it with `from: "1.0.0"`; nothing else in the flow changes.

## Consuming the package

During the beta the repository is private. An app developer needs a GitHub account
with read access to it, signed in under Xcode → Settings → Accounts. CI systems
building the app use a token with read access, for example through
`git config --global url."https://x-access-token:<token>@github.com/".insteadOf "https://github.com/"`
in the build environment, never in the app repository. The README's **Install**
section has the snippet.

## Branch and tag protection

Repository rulesets, all with **no bypass actors** (admins included):

| Ruleset | Target | Rules |
|---|---|---|
| `protect-main` | the default branch | no deletion, no force-push, linear history; pull request required with 1 approval, code-owner review, stale approvals dismissed on push, last push approved by someone else, all threads resolved, squash merge only; required checks `Swift style`, `Static analysis`, `API contract`, `Tests & coverage`, `SonarQube`, `Build`, strict (branch up to date) |
| `protect-tags` | all tags | no deletion, no force-push (a tag never moves) |
| `release-tags` | `v*` tags | creation restricted; bypass: repository admins (creating a release tag is the privileged act) |

Repository settings that go with them: squash merge only, branches deleted on
merge, Dependabot alerts and security updates on, Actions limited to GitHub-owned
and verified creators plus `actions/*` and `SonarSource/sonarqube-scan-action`,
default `GITHUB_TOKEN` read-only, Actions may not create or approve pull requests.

`.github/CODEOWNERS` lists the sensitive paths (workflows, hooks, the manifest and
`Package.resolved`, the version in `Support.swift`, the privacy manifest, the API dump
and its tools, the shared fixtures, the lint and Sonar configs, the policy docs); a
maintainer must approve changes to them.

## Pinned dependencies

`Package.resolved` is committed and pins every dependency to a revision (a commit
SHA, not only a version). CI resolves with `--force-resolved-versions` and Xcode with
`-onlyUsePackageVersionsFromResolvedFile`, so a build uses exactly those revisions and
fails, rather than silently re-resolving, when the manifest asks for something else.
This is the Swift counterpart of the Android SDK's Gradle dependency verification.

- A dependency bump, Dependabot's included, changes `Package.resolved`; review that
  diff (the revision is the code that will ship inside apps).
- The base library (`analytics-swift`) is excluded from Dependabot: its version is part
  of the wire contract (`context.library.base`) and moves together with the Android SDK.

## Tool versions

| Tool | Where it is pinned | How to move it |
|---|---|---|
| swift-format | `container:` of the **Swift style** job (`swift:<version>-noble@sha256:…`) | look up the new tag's digest on Docker Hub and change the line |
| SwiftLint | `container:` of the **Static analysis** job (`ghcr.io/realm/swiftlint:<version>@sha256:…`) | the new tag's digest from `ghcr.io` |
| XcodeGen | `XCODEGEN_VERSION` and `XCODEGEN_SHA256` in the **Build** job | the release asset's sha256 from its GitHub release page |
| Xcode | the `macos-26` runner image's default Xcode | change the runner label |

Dependabot does not update `container:` images in workflows, hence the table. The
CI formatter is the reference; a Mac's `xcrun swift-format` comes from its Xcode and
can differ in rare cases. When it does, CI's output wins.

## Local counterparts

| Gate | Locally (a Mac with Xcode 26) |
|---|---|
| Swift style | `swift format lint --strict --recursive Package.swift Sources Tests Example`; fix with `swift format --in-place --recursive …` |
| Static analysis | `swiftlint lint --strict` (`brew install swiftlint`) |
| Public API dump | `tools/api_dump.sh` after an intentional API change; review the diff of `api/SfereAnalytics.api`. `tools/api_dump.sh --check` only compares |
| Tests | `swift test` |
| Build | `xcodebuild build -quiet -scheme SfereAnalytics -destination 'generic/platform=iOS Simulator'` and the sample app (VS Code tasks **iOS: build for Simulator**, **iOS: build sample app**) |
| Everything above | VS Code task **iOS: quality checks** |
| Pre-commit hook | `git config core.hooksPath .githooks` once per clone: swift-format on the staged Swift, the API dump when the SDK sources are staged, and the vendor-name check |

## Secrets and variables

| Name | Where | Used by |
|---|---|---|
| `SONAR_TOKEN` | repository secret (set 2026-10-20) | the `SonarQube` job. SonarQube Cloud project `sfere-io_sfere-ios-sdk` in organization `sfere-io`: https://sonarcloud.io/project/overview?id=sfere-io_sfere-ios-sdk |
| `GITHUB_TOKEN` | automatic | resolving the tag in the release job, the GitHub release |

No deploy keys, no personal tokens, no cloud credentials: the SDK ships as git tags.

## Not yet in CI

- **Cross-repo parity with the Android SDK.** `tools/parity.sh` needs both repositories
  side by side, Xcode and the Android toolchain (plan step F1). Until a macOS job with
  access to `sfere-io/sfere-android-sdk` exists, run it locally before merging a change
  to what the SDK sends.
- **Simulator flows.** `tools/ios_flows.py` (fresh install, upgrade, deep links,
  consent, opt-out, retries, the offline queue) takes about 10 minutes and a few GB of
  memory on a booted simulator. CI compiles the UI tests but does not run them; a
  nightly or `main`-only macOS job is the next step, as decision Q7 says.
