# Repository Guidelines

## Project Structure & Module Organization

Light Anchor is a Swift 6 package targeting macOS 15. The SwiftUI app is in `Sources/LightAnchor/`: `App/` wires runtime state, `Domain/` defines models and events, `Services/` owns persistence and integrations, `Views/` contains UI, and `Design/` holds theme primitives. Localizations are under `Resources/{zh-Hans,en}.lproj/`. The event protocol and CLI are separate targets in `Sources/LightAnchorEventCore/` and `Sources/LightAnchorEvent/`. Tests live in `Tests/LightAnchorTests/`. Use `Scripts/` for operational tooling, `Integrations/` for external-agent adapters, and `Support/` for entitlements, icons, and brand assets.

## Build, Test, and Development Commands

- `swift run LightAnchor` builds and launches the development executable.
- `swift test` runs the full XCTest suite.
- `swift build -c release` verifies an optimized production build.
- `Scripts/build-release.sh` creates the app bundle, archive, and update manifest in `dist/`.
- `Scripts/verify-release.sh` tests and validates the release bundle; `Scripts/audit-release.sh` runs the broader release audit.
- `Scripts/smoke-macos-app.sh` exercises launch, deep links, event persistence, and clean shutdown with isolated data.

Release scripts require macOS tooling; some also check for `jq` and `openssl`.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, braces on the declaration line, `UpperCamelCase` types, and `lowerCamelCase` members. Keep files focused and place code in the matching layer. Mark UI-bound state with `@MainActor` where appropriate. No formatter or linter is configured, so match nearby code and keep `swift build` warning-free.

All visible UI text must use `tr("stable_english_key")`. Add identical key sets to both localization tables; `zh-Hans` is the source of truth. Do not edit generated `LightAnchorNavGlyphs.swift`; regenerate it with `Scripts/import-lucide-glyphs.py`. Shell scripts use zsh with `set -euo pipefail`.

## Testing Guidelines

Tests use XCTest. Name files `FeatureTests.swift`, classes `FeatureTests`, and methods `testExpectedBehavior`. Add regression tests for behavior changes, especially event replay, persistence, privacy filtering, and localization. No numeric coverage threshold is defined; changed behavior should be directly exercised. Run `swift test` before every pull request and the relevant smoke script for release, backup, integration, or lifecycle changes.

## Commit & Pull Request Guidelines

Commits follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): subject` with type in `feat|fix|refactor|perf|style|test|docs|build|ci|chore|revert`, an optional lowercase scope (directory or feature area, e.g. `scene`, `sidebar`, `l10n`, `release`), and a subject ≤ 72 characters with no trailing period — Chinese or English, Chinese is the norm here. Mark breaking changes with `!` plus a `BREAKING CHANGE:` footer. Run `Scripts/setup-git.sh` once per clone to enable the `.githooks/commit-msg` validator and `.gitmessage` template; the full convention lives in `docs/development.md`. Keep commits focused. Pull requests should explain the user-visible effect, note architectural or data-format changes, list verification commands, and link relevant issues. Include screenshots for UI changes and update both localization tables when copy changes. Never commit `.build/`, `dist/`, credentials, signing keys, or real user data.
