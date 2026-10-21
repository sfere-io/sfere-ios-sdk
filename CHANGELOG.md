# Changelog

All notable changes to the Sfere iOS SDK (Swift package `SfereAnalytics`). The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
semantic versioning once 1.0.0 ships. The `release` workflow uses the section for
the tagged version as the GitHub release notes, so write entries for app developers.

## [Unreleased]

## [0.1.0] - 2026-10-21

The first public release. The SDK code is the same as 0.1.0-beta.2; what changes is
how you install it. Versions stay at 0.x for now, so a minor version can still change
the public API.

### Changed

- The repository is public. Add the package from
  `https://github.com/sfere-io/sfere-ios-sdk.git` in Xcode (File > Add Package
  Dependencies) or in `Package.swift`. No GitHub account is needed.
- Depend on it with `from: "0.1.0"` and the `SfereAnalytics` product. You no longer
  pin a beta with `exact:`.
- Events carry `context.library.version` `0.1.0`.
- The README's setup example points at Sfere's ingestion host,
  `https://events.sfere.io`.

### Included

Everything from the betas:

- `Sfere.setup`, `track`, `screen`, `identify`, `group`, `alias`, `purchase` (GA4
  e-commerce keys), `flush`, `reset`, `setConsent`, `setEnabled` and `openURL`, on the
  base library analytics-swift 1.10.
- Lifecycle events `app_installed`, `app_updated`, `app_opened`, `app_backgrounded`,
  `session_started` and `deep_link_opened`, with GA4-style snake_case names.
- Click IDs and UTMs from deep links in `context.clientIds` and `context.campaign`.
- Consent (`context.consent`) and opt-out, both remembered across launches.
- An on-disk event queue with batched uploads to `POST {host}/v1/batch/b` only, and
  retries after network errors, `5xx` and `429`.
- A privacy manifest (`PrivacyInfo.xcprivacy`) bundled with the package. No device
  identifier is sent.

## [0.1.0-beta.2] - 2026-10-20

The first published beta: same SDK as 0.1.0-beta.1, whose tag exists but whose release
run stopped before the GitHub release (a bug in the release workflow, not in the SDK).

### Fixed

- The release workflow builds the throwaway app package it uses to check the tag.

## [0.1.0-beta.1] - 2026-10-20

### Added

- First beta of the SDK on the base library (analytics-swift 1.10): `Sfere.setup`,
  `track`, `screen`, `identify`, `group`, `alias`, `purchase` (GA4 e-commerce keys),
  `flush`, `reset`, `setConsent`, `setEnabled`, `openURL`.
- Lifecycle events `app_installed`, `app_updated`, `app_opened`, `app_backgrounded`,
  `session_started` and `deep_link_opened`, with GA4-style snake_case names.
- Click IDs and UTMs from deep links in `context.clientIds` and `context.campaign`.
- Consent (`context.consent`) and opt-out, both remembered across launches.
- Uploads to `POST {host}/v1/batch/b` only, with Basic auth; no `_metadata`,
  no empty `integrations`, no `context.instanceId`, no `context.device.id`.
- A privacy manifest (`PrivacyInfo.xcprivacy`) bundled with the package.
- Distribution as a Swift package from this repository's tags
  (`https://github.com/sfere-io/sfere-ios-sdk.git`, the organization renamed from
  fanfinity to sfere-io on 2026-10-20); CI gates on every pull request (style, static
  analysis, public API dump, tests with coverage, build).
