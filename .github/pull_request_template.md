## What

<!-- What does this PR change? -->

## Why

<!-- Link the issue or context. Why is this the right change? -->

## How was this tested

All commands run from the repository root on a Mac with Xcode 26 (`TESTING.md`).

- [ ] `swift test` (or explain why not applicable)
- [ ] `swift format lint --strict --recursive Package.swift Sources Tests Example` and `swiftlint lint --strict`
- [ ] `tools/api_dump.sh --check` (run `tools/api_dump.sh` and commit the dump if the public API changed)
- [ ] `tools/parity.sh` against `sfere-android-sdk` (if what the SDK sends changed)
- [ ] `python3 -I tools/ios_flows.py` (if lifecycle, deep links, consent or the queue changed)

## Checklist

- [ ] Follows `CLAUDE.md` (wire shape, event names, no hashing, no third-party hosts)
- [ ] A change to what the SDK sends has the matching change in `sfere-android-sdk` (same round)
- [ ] `CHANGELOG.md` has an entry under `## [Unreleased]` (SDK changes; label `skip-changelog` otherwise)
- [ ] `SfereVersion.current` in `Sources/SfereAnalytics/Support.swift` is not an already-tagged version
- [ ] Public API change: `api/SfereAnalytics.api` regenerated and reviewed
- [ ] No vendor name for the ingestion platform anywhere (say "ingestion endpoint")
- [ ] No secrets or real write keys in the diff (`.env` is git-ignored; tests use `sferetest` keys)
- [ ] Dependency change: `Package.resolved` committed and its diff reviewed
- [ ] CI or release changes (`.github/**`, `.githooks/**`, `sonar-project.properties`) come with a `docs/ci-cd.md` update
