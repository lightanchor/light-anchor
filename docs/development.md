# 开发与发布

面向在这个仓库里干活的人。产品是什么、给谁用，见 [`../README.md`](../README.md)。

## 项目结构

Swift 6 包，目标 macOS 15，没有 Xcode 工程文件。`Sources/LightAnchor/` 是 SwiftUI 应用（`App/` 运行时状态、`Domain/` 模型与事件、`Services/` 持久化与系统能力、`Views/` 界面、`Design/` 主题原语），测试在 `Tests/LightAnchorTests/`。`Scripts/` 放运维工具，`Support/` 放权利文件、图标与品牌素材。逐条约定见 [`../AGENTS.md`](../AGENTS.md)。

## 运行与验证

```text
swift test                              # 全部自动化测试
swift build -c release
Scripts/build-release.sh                # 出 dist/LightAnchor.app + zip + manifest
Scripts/verify-release.sh
Scripts/audit-release.sh                # 串起性能基线、备份、签名、发布的完整审计
Scripts/smoke-macos-app.sh              # 真实 App 包启动、深链、退出清理烟测
Scripts/smoke-data-backup.sh
Scripts/smoke-release-signature.sh
Scripts/smoke-update-release.sh
Scripts/reset-permissions.sh            # 清掉本机 TCC 授权记录，重新走一遍授权
```

`Scripts/smoke-macos-app.sh` 在临时 `LIGHTANCHOR_DATA_ROOT` 下启动真实 App 包，验证进程存活、`lightanchor://capture` 深链落进事件日志和退出清理，不污染默认数据目录；日常运行也可以用同一变量指定隔离数据根。

## 提交信息

提交信息遵循 [Conventional Commits 1.0.0](https://www.conventionalcommits.org/zh-hans/v1.0.0/)：

```text
type(scope): 一句话说清这次提交做了什么

（可选正文：动机、取舍、影响面。）

（可选脚注：BREAKING CHANGE: …、Refs #123、Co-Authored-By: … 等。）
```

- **type**（必填）：`feat` 新能力或新界面形态 · `fix` 修行为或视觉问题 · `refactor` 不改行为的整理 · `perf` 性能 · `test` 测试 · `docs` 文档 · `build` 构建与依赖 · `ci` 持续集成 · `chore` 杂务（脚本、种子数据、仓库配置等）· `style` 纯代码排版 · `revert` 还原。
- **scope**（可选）：小写，按目录或功能面取，如 `scene`、`sidebar`、`review`、`settings`、`design`、`l10n`、`release`。
- **主题行**：中文或英文都行（本仓库以中文为主），直接陈述改了什么，结尾不加句号，整行 ≤ 72 字符。破坏性变更在冒号前加 `!`，并在脚注写 `BREAKING CHANGE:`。
- 一次提交聚焦一件事；界面改动在 PR 里附截图（见 [`../AGENTS.md`](../AGENTS.md)）。

克隆后执行一次 `Scripts/setup-git.sh`，启用 `.githooks/commit-msg` 校验与 `.gitmessage` 模板。应急可 `git commit --no-verify` 绕过，但不合规的主题不要推上 main。

示例：

```text
feat(scene): 放下确认弹窗加「回来先看」输入框
fix(sidebar): 现场舱开着时收展动画被吞——宽度动画钉在 sidebarAnchored 上
refactor(design): SegSoft 与 SectionLabel 去掉自带外边距，行距交调用处
chore(release): 更新 manifest 校验和与签名脚本
```

## 发布与更新

`Scripts/build-release.sh` 生成 `dist/LightAnchor.app`、可分发 zip、带 checksum 的 update manifest 和可选 RSA 签名。没有 Developer ID 或更新私钥时仍可出未签名本地包；正式分发需要 `LIGHTANCHOR_SIGNING_IDENTITY`、`LIGHTANCHOR_UPDATE_PRIVATE_KEY` 与对应公钥。

快捷指令（App Intents）靠包里的 `Contents/Resources/Metadata.appintents` 被系统发现，`swift build` 不会生成它。`build-release.sh` 照 Xcode 的 ExtractAppIntentsMetadata 阶段自己做：编译时加 `-emit-const-values` 与 `-const-gather-protocols-file`（协议名单写在 `.build/appintents/`），让 swiftc 把 `AppIntent` / `AppShortcutsProvider` 实现抽成 `.swiftconstvalues`，再在签名之前用 `xcrun appintentsmetadataprocessor --compile-time-extraction` 把它们写成元数据。处理器只随 Xcode 分发，只装 Command Line Tools 的机器会直接报错停下；确实不需要快捷指令的本地包可用 `LIGHTANCHOR_SKIP_APPINTENTS_METADATA=1` 跳过，`verify-release.sh` 按同一变量跳过检查，否则它会核对源码里每个 `AppIntent` 都出现在 `extract.actionsdata` 里。CI 的 `release-bundle` 任务在带 Xcode 的 runner 上跑完整个流程并断言三条 intent 都在。Info.plist 无需为此加任何键。

公证必须在打包之前完成——`stapler` 会改写 App，之后再打包就和 manifest 里的校验和对不上。设置 `LIGHTANCHOR_NOTARY_PROFILE` 后直接跑 `build-release.sh`，它会在签名与打包之间提交公证并盖章；`Scripts/notarize-release.sh` 只用于单独公证已有 App 包。`LIGHTANCHOR_DIST_DIR` 可把产物输出到隔离目录。

本机自用的安装路径：直接 `open dist/LightAnchor.app` 或整包拷到「应用程序」。没有 Developer ID 时脚本会做 ad-hoc 签名（带完整 bundle 封条）；**不要用 Finder/Keka 解压 dist 里的 zip 再运行**——解压工具会给产物打 `com.apple.quarantine`，隔离 + ad-hoc 会被 Gatekeeper 报「已损坏」。误触发后一行解除：`xattr -dr com.apple.quarantine /path/to/LightAnchor.app`。每次 ad-hoc 换包 CDHash 都变，TCC 权限（辅助功能/屏幕录制等）需要重授：旧那条授权会留在系统设置列表里、开关看着是开的却对不上新包，表现为「辅助功能明明开着却没用」。退出轻锚后跑 `Scripts/reset-permissions.sh` 清掉记录，再重新添加即可；权限页在这种构建下也会把这句提示直接写在辅助功能那一行。

安装更新用 `Scripts/install-release.sh /path/to/Signed.app /Applications/LightAnchor.app`：拒绝未签名、ad-hoc 或 bundle identifier 不匹配的包，先 staging 再替换并把上一版本留在 `mktemp` 建的槽位里。设置 `LIGHTANCHOR_TEAM_ID` 后会用 designated requirement 钉住签名者的 Team ID；公证检查默认开启（`LIGHTANCHOR_REQUIRE_NOTARIZATION=1`，要求 `spctl` 给出 `source=Notarized Developer ID`）。本地烟测装 ad-hoc 包需显式 `LIGHTANCHOR_ALLOW_ADHOC_SIGNATURE=1 LIGHTANCHOR_REQUIRE_NOTARIZATION=0`。`Scripts/update-release.sh` 在签名与 zip 校验之后还会核对 manifest 里的 `binarySHA256`。

更新信任锚随构建内置：`build-release.sh` 在设置了 `LIGHTANCHOR_UPDATE_PRIVATE_KEY` 时把派生出的公钥写成 `Sources/LightAnchor/Resources/update-public.pem` 打进包里（构建结束即删除，且已在 `.gitignore`），应用检测到内置公钥就只认它，不再读 UserDefaults 里的公钥路径；备份恢复也永不写回更新地址与公钥路径。`Scripts/update-release.sh` 核对构建号并拒绝降级（`LIGHTANCHOR_ALLOW_DOWNGRADE=1` 可覆盖）。manifest 一律用 `jq` 按 JSON 解析，不走 `plutil`。应用内的签名更新检查从当前 bundle 读版本号，避免把开发期默认值误报为新版本。

## 数据与隐私

- 所有记录都在本机：事件溯源日志 `events.json` 是唯一真相，附件在同目录 `assets/`。日志带 `schemaVersion`，版本不符整份拒绝读取，不做兼容解码。
- `Scripts/backup-data.sh` 生成带 schema、文件大小和 SHA-256 manifest 的 `.tar.gz`；`Scripts/restore-data.sh --backup PATH --verify` 只校验，真正恢复必须显式 `--replace`，旧目录保留为 `.pre-restore-*`。
- 设置 → 数据 提供 JSON 导出、诊断导出（脱敏）、完整备份/恢复和收件箱自动归档配置。备份里除了数据目录还含一份偏好快照（`preferences.plist`）：回顾正文、云端配置、快捷键、采集偏好都在 UserDefaults 里，不一起打包，换机恢复会静静丢掉它们。恢复只写清单内的键——备份文件是外部输入，不让它往 UserDefaults 里塞任意键；包里没有这个文件视为结构不完整，整体拒绝恢复。备份文件被当作**不可信输入**：恢复前先在临时目录里解一遍 `events.json`、拒绝符号链接（含隐藏项）并限制解压总量；恢复后环境里的「运行命令 / 快捷指令」动作被停用、云端引擎与整屏截图 / 剪贴板采集回到关闭，更新地址与公钥路径永不写回；附件路径只认 `assets/` 目录内的平铺文件。云端 API Key 存在 Keychain 里，不在偏好 blob 中，因此也不在备份里。每次恢复留下的 `.pre-restore-*` 副本只保留最近一份，「删除全部本地数据」会一并清掉。
- 「删除全部本地数据」的删/留清单在 `LocalDataErasure` 一处定义：内容、凭据（云端 API Key）与缓存必删，界面与隐私偏好刻意保留——删数据不该把用户收紧过的采集开关退回更宽松的默认。守门测试核对源码里每个偏好键都被显式分类。
- 权限五项（麦克风、语音识别、屏幕录制、辅助功能、通知）全部按用途显示状态并跳系统设置，应用不代替用户授权。麦克风/语音识别/通知会弹窗要答案；辅助功能和屏幕录制的开关在系统设置里，系统不会回一个明确的「拒绝」，所以这两项只报「待系统设置里开启」，并在权限页开着时按秒复查——拨完开关切回来就是「已授权」。屏幕录制的授权在进程内被缓存，拨完要重开轻锚。
- 设置 → 权限 可暂停自动现场记录，并按应用 Bundle ID 或网站域名选择「排除列表」/「只记录列表」；规则在读取窗口与终端事实之前生效。这里也可清除最近一小时或全部现场事实与截图，同时保留目标状态、用户备注和专注账本。

## 本地化

本地化 key 是稳定的英文标识符（如 `save`、`ready_to_return`），所有用户可见文案走 `tr()`。简体中文是开发语言：`Sources/LightAnchor/Resources/zh-Hans.lproj/` 是唯一事实源，`en.lproj/` 逐 key 对照翻译；查找顺序「当前语言 → zh-Hans → key」，漏译只会回退中文、不会坏。加新语言 = 加一个 `.lproj` 目录，零代码改动。表随 SPM 资源 bundle（`Bundle.module`）走，`swift run` 开发期同样生效；语言切换写系统 `AppleLanguages` 覆盖，重开应用生效。含插值的文案走 `String(format: tr(...))`，语序不同的语言用位置说明符（`%2$@`）调换实参。守门测试保证两表 key 集一致、格式占位符一致、`tr()` 的 key 都在表里、表里没有没人用的 key，界面层与已收口的服务文件没有裸中文字面量。

三处刻意还没双语，源码里各自写了理由与后果：**提示词与模型输入**留中文，所以界面切到英文时 AI 生成的回答仍是中文（要改是整套提示词按语言出版本，并定一条策略：跟界面语言还是跟提问语言）；**中文问句的分词表**（时间词与套话）是解析器而非文案，英文提问现在解析不出时间范围、只会退到默认最近 7 天，那是没做的功能不是漏译；**App Intents 的标题与说明**用 `LocalizedStringResource`，构建期抽进「快捷指令」元数据、取主 bundle 的表，与 `tr()` 的 `Bundle.module` 不是一条路。

## 文档地图

| 文档 | 说明 |
| --- | --- |
| [`../AGENTS.md`](../AGENTS.md) | 仓库约定：结构、命令、代码风格、测试与提交要求 |
| [`chat-memory-design.md`](./chat-memory-design.md) | 「对话」页三种记忆与检索的设计与验收标准 |
| [`design/README.md`](./design/README.md) | 界面视觉基准（已冻结，不再更新） |
| [`../Support/Brand/BRAND.md`](../Support/Brand/BRAND.md) | 「蜜芽方块」品牌与菜单栏蓝点形态 |

## 第三方素材

- 侧栏导航字形：[Lucide](https://github.com/lucide-icons/lucide)（ISC License，源自 Feather 的部分为 MIT）。只保留实际用到的 SVG，见 [`Support/Icons/lucide/`](../Support/Icons/lucide/)（含 LICENSE 与更新说明）。字形经 `Scripts/import-lucide-glyphs.py` 转成 `Sources/LightAnchor/Design/LightAnchorNavGlyphs.swift`，该文件由脚本生成，勿手改；线宽和颜色由渲染侧给（侧栏 1.75 / 24 网格，单色跟随 `foregroundStyle`）。
- 应用/菜单栏图标（蜜芽方块）是自绘，不走本条。
