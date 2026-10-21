# Security Policy

## Reporting a Vulnerability

This repository is public. Please do **not** open a public issue or discuss the
vulnerability in a pull request.

Report vulnerabilities privately to the repository administrators
(@mabumusa1, @KaramYaaqba) — never in an issue or pull request. Contact the
maintainers directly (GitHub DM or email), or open a private security advisory
from the repository's Security tab if you have write access.

Include:

- A description of the issue and its impact
- Steps to reproduce or a proof of concept
- Affected files, commits, or versions if known

We will acknowledge the report within a few working days and keep you updated on
the fix and disclosure timeline.

## Scope

- The SDK (`Sources/SfereAnalytics/`), its manifest and pinned dependencies
  (`Package.swift`, `Package.resolved`), its privacy manifest, and the CI/release
  workflows (`.github/workflows/**`, `.githooks/**`)
- The released versions, i.e. the `v*` tags apps resolve the package from
- Dependency vulnerabilities in the resolved dependency graph (tracked via
  Dependabot alerts and security updates)

Out of scope: the sample app (`Example/`), the mock ingestion server
(`tools/mock_ingest.mjs`) and the other scripts in `tools/`, which are test tooling
and never ship to users.

## What the SDK promises

- It talks only to the host the app configures (`{host}/v1/batch/b`); tests assert
  that no other request is made, and telemetry to third parties is off.
- It never hashes or reformats email or phone values.
- It sends no device identifier, and its privacy manifest says what it collects.
- It never throws into or traps the host app.

## Preferred Practices

- Never commit secrets. Write keys for staging live in the git-ignored `.env`;
  tests use `sferetest` keys.
- All changes to `main` go through a reviewed pull request; direct pushes,
  force-pushes, and deletions are blocked by repository rulesets.
- Release tags (`v*`) can be created by repository admins only, and no tag can be
  moved or deleted: a released version is immutable.
