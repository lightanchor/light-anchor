# Repository Guidelines

## AI 执行规则

1. **发布前只维护当前设计。** 用户最新确认的想法和需求优先于历史实现、旧设计文档和旧测试；直接替换旧方案，同步清理死代码、测试和文案。发布前只有当前这一套实现和数据结构，不设 v2/v3 等数据版本门槛，不新增或保留历史兼容层、迁移分支、双轨实现及兜底映射。用户已授权：发布前 LightAnchor 的本地开发数据均可删除，必要时直接清空重建，无需为保留旧数据改变设计或反复征求确认。执行清理时先核对应用自有数据范围、停止相关写入并说明清理范围；不得扩展到项目源码、用户引用的原始文件、其他应用或远端数据，也不把启动时的读取失败改成自动删库。当前支持的系统/API 适配、权限检查和数据安全校验仍须保留。
2. **页面大改后直接交付安装包。** 涉及页面结构、导航、主要交互或大面积视觉调整时，完成修改后主动执行测试、`Scripts/build-release.sh`、`Scripts/verify-release.sh` 和隔离数据的 `LIGHTANCHOR_SKIP_BUILD=true Scripts/smoke-macos-app.sh`，并检查修改页面、提供截图。无需等用户再次要求打包；最终交付本次生成的 `.app` 和 `.zip` 的实际路径及验证结果。构建或验证失败时说明阻塞，不得拿旧包冒充本次产物；缺少签名或公证时明确标注本地测试包，不擅自安装或覆盖用户现有应用。

## Project Structure & Module Organization

Light Anchor is a Swift 6 package targeting macOS 15. The SwiftUI app is in `Sources/LightAnchor/`: `App/` wires runtime state, `Domain/` defines models and events, `Services/` owns persistence and system capabilities, `Views/` contains UI, and `Design/` holds theme primitives. Localizations are under `Resources/{zh-Hans,en}.lproj/`. Tests live in `Tests/LightAnchorTests/`. Use `Scripts/` for operational tooling and `Support/` for entitlements, icons, and brand assets.

## Build, Test, and Development Commands

- `swift run LightAnchor` builds and launches the development executable.
- `swift test` runs the full XCTest suite.
- `swift build -c release` verifies an optimized production build.
- `Scripts/build-release.sh` creates the app bundle, archive, and update manifest in `dist/`.
- `Scripts/verify-release.sh` tests and validates the release bundle; `Scripts/audit-release.sh` runs the broader release audit.
- `Scripts/smoke-macos-app.sh` exercises launch, the `lightanchor://capture` deep link, and clean shutdown with isolated data.

Release scripts require macOS tooling; some also check for `jq` and `openssl`.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, braces on the declaration line, `UpperCamelCase` types, and `lowerCamelCase` members. Keep files focused and place code in the matching layer. Mark UI-bound state with `@MainActor` where appropriate. No formatter or linter is configured, so match nearby code and keep `swift build` warning-free.

All visible UI text must use `tr("stable_english_key")`. Add identical key sets to both localization tables; `zh-Hans` is the source of truth. Do not edit generated `LightAnchorNavGlyphs.swift`; regenerate it with `Scripts/import-lucide-glyphs.py`. Shell scripts use zsh with `set -euo pipefail`.

## Testing Guidelines

Tests use XCTest. Name files `FeatureTests.swift`, classes `FeatureTests`, and methods `testExpectedBehavior`. Add regression tests for behavior changes, especially event replay, persistence, privacy filtering, and localization. No numeric coverage threshold is defined; changed behavior should be directly exercised. Run `swift test` before every pull request and the relevant smoke script for release, backup, or lifecycle changes.

## Commit & Pull Request Guidelines

Commits follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/): `type(scope): subject` with type in `feat|fix|refactor|perf|style|test|docs|build|ci|chore|revert`, an optional lowercase scope (directory or feature area, e.g. `scene`, `sidebar`, `l10n`, `release`), and a subject ≤ 72 characters with no trailing period — Chinese or English, Chinese is the norm here. Mark breaking changes with `!` plus a `BREAKING CHANGE:` footer. Run `Scripts/setup-git.sh` once per clone to enable the `.githooks/commit-msg` validator and `.gitmessage` template; the full convention lives in `docs/development.md`. Keep commits focused. Pull requests should explain the user-visible effect, note architectural or data-format changes, list verification commands, and link relevant issues. Include screenshots for UI changes and update both localization tables when copy changes. Never commit `.build/`, `dist/`, credentials, signing keys, or real user data.
