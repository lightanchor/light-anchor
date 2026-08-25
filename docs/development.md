# 开发与发布

面向在这个仓库里干活的人。产品是什么、给谁用，见 [`../README.md`](../README.md)。

## 项目结构

Swift 6 包，目标 macOS 15，没有 Xcode 工程文件。`Sources/LightAnchor/` 是 SwiftUI 应用（`App/` 运行时状态、`Domain/` 模型与事件、`Services/` 持久化与集成、`Views/` 界面、`Design/` 主题原语），事件协议与 CLI 是独立 target `Sources/LightAnchorEventCore/`、`Sources/LightAnchorEvent/`，测试在 `Tests/LightAnchorTests/`。`Scripts/` 放运维工具，`Integrations/` 放外部 agent 适配器，`Support/` 放权利文件、图标与品牌素材。逐条约定见 [`../AGENTS.md`](../AGENTS.md)。

## 运行与验证

```text
swift test                              # 全部自动化测试（当前 286 项）
swift build -c release
Scripts/build-release.sh                # 出 dist/LightAnchor.app + zip + manifest
Scripts/verify-release.sh
Scripts/audit-release.sh                # 串起性能基线、备份、签名、发布的完整审计
Scripts/smoke-macos-app.sh              # 真实 App 包启动、深链、退出清理烟测
Scripts/smoke-data-backup.sh
Scripts/smoke-release-signature.sh
Scripts/smoke-update-release.sh
Scripts/reset-permissions.sh            # 清掉本机 TCC 授权记录，重新走一遍授权
Scripts/lightanchor-event.sh publish --help
```

`Scripts/smoke-macos-app.sh` 在临时 `LIGHTANCHOR_DATA_ROOT` 下启动真实 App 包，验证进程存活、`lightanchor://event` 深链、事件落盘和退出清理，不污染默认数据目录；日常运行也可以用同一变量指定隔离数据根。

## 发布与更新

`Scripts/build-release.sh` 生成 `dist/LightAnchor.app`、可分发 zip、带 checksum 的 update manifest 和可选 RSA 签名。没有 Developer ID 或更新私钥时仍可出未签名本地包；正式分发需要 `LIGHTANCHOR_SIGNING_IDENTITY`、`LIGHTANCHOR_UPDATE_PRIVATE_KEY` 与对应公钥。

公证必须在打包之前完成——`stapler` 会改写 App，之后再打包就和 manifest 里的校验和对不上。设置 `LIGHTANCHOR_NOTARY_PROFILE` 后直接跑 `build-release.sh`，它会在签名与打包之间提交公证并盖章；`Scripts/notarize-release.sh` 只用于单独公证已有 App 包。`LIGHTANCHOR_DIST_DIR` 可把产物输出到隔离目录。

本机自用的安装路径：直接 `open dist/LightAnchor.app` 或整包拷到「应用程序」。没有 Developer ID 时脚本会做 ad-hoc 签名（带完整 bundle 封条）；**不要用 Finder/Keka 解压 dist 里的 zip 再运行**——解压工具会给产物打 `com.apple.quarantine`，隔离 + ad-hoc 会被 Gatekeeper 报「已损坏」。误触发后一行解除：`xattr -dr com.apple.quarantine /path/to/LightAnchor.app`。每次 ad-hoc 换包 CDHash 都变，TCC 权限（辅助功能/屏幕录制等）需要重授：旧那条授权会留在系统设置列表里、开关看着是开的却对不上新包，表现为「辅助功能明明开着却没用」。退出轻锚后跑 `Scripts/reset-permissions.sh` 清掉记录，再重新添加即可；权限页在这种构建下也会把这句提示直接写在辅助功能那一行。

安装更新用 `Scripts/install-release.sh /path/to/Signed.app /Applications/LightAnchor.app`：拒绝未签名、ad-hoc 或 bundle identifier 不匹配的包，先 staging 再替换并保留上一版本；本地烟测装 ad-hoc 包需显式 `LIGHTANCHOR_ALLOW_ADHOC_SIGNATURE=1`。`Scripts/update-release.sh` 核对构建号并拒绝降级（`LIGHTANCHOR_ALLOW_DOWNGRADE=1` 可覆盖）。manifest 一律用 `jq` 按 JSON 解析，不走 `plutil`。应用内的签名更新检查从当前 bundle 读版本号，避免把开发期默认值误报为新版本。

## 数据与隐私

- 所有记录都在本机：事件溯源日志 `events.json` 是唯一真相，附件在同目录 `assets/`。旧日志里已被移除的事件类型经 `unsupported` 哨兵兼容跳过。
- `Scripts/backup-data.sh` 生成带 schema、文件大小和 SHA-256 manifest 的 `.tar.gz`；`Scripts/restore-data.sh --backup PATH --verify` 只校验，真正恢复必须显式 `--replace`，旧目录保留为 `.pre-restore-*`。
- 设置 → 数据 提供 JSON 导出、诊断导出（脱敏）、完整备份/恢复和收件箱自动归档配置。备份里除了数据目录还含一份偏好快照（`preferences.plist`）：回顾正文、云端配置、快捷键、采集偏好都在 UserDefaults 里，不一起打包，换机恢复会静静丢掉它们。恢复只写清单内的键——备份文件是外部输入，不让它往 UserDefaults 里塞任意键；老备份没有这个文件时跳过。
- 「删除全部本地数据」的删/留清单在 `LocalDataErasure` 一处定义：内容、凭据（云端 API Key）与缓存必删，界面与隐私偏好刻意保留——删数据不该把用户收紧过的采集开关退回更宽松的默认。守门测试核对源码里每个偏好键都被显式分类。
- 权限五项（麦克风、语音识别、屏幕录制、辅助功能、通知）全部按用途显示状态并跳系统设置，应用不代替用户授权。麦克风/语音识别/通知会弹窗要答案；辅助功能和屏幕录制的开关在系统设置里，系统不会回一个明确的「拒绝」，所以这两项只报「待系统设置里开启」，并在权限页开着时按秒复查——拨完开关切回来就是「已授权」。屏幕录制的授权在进程内被缓存，拨完要重开轻锚。
- 设置 → 权限 可暂停自动现场记录，并按应用 Bundle ID 或网站域名选择「排除列表」/「只记录列表」；规则在读取窗口与终端事实之前生效。这里也可清除最近一小时或全部现场事实与截图，同时保留目标状态、用户备注和专注账本。

## 外部结果交接

构建、下载、导出或任何外部任务都可以发布统一完成事件，等待项只匹配自己声明的 `correlationID`：

```text
Scripts/lightanchor-event.sh publish \
  --source terminal \
  --kind completed \
  --correlation build-42 \
  --title "项目构建" \
  --detail "测试通过"
```

也可以打开 `lightanchor://event?source=terminal&kind=completed&correlation=build-42`；带 URL 的 `lightanchor://` 深链直接落收件箱。事件日志在应用支持目录持久化，应用重启后继续监视已声明的等待。五个工作台（Claude Code / Codex / PI / dsh / 终端）的手动接入路径见 [`Integrations/`](../Integrations/README.md)。

## 本地化

本地化 key 是稳定的英文标识符（如 `save`、`ready_to_return`），所有用户可见文案走 `tr()`。简体中文是开发语言：`Sources/LightAnchor/Resources/zh-Hans.lproj/` 是唯一事实源，`en.lproj/` 逐 key 对照翻译；查找顺序「当前语言 → zh-Hans → key」，漏译只会回退中文、不会坏。加新语言 = 加一个 `.lproj` 目录，零代码改动。表随 SPM 资源 bundle（`Bundle.module`）走，`swift run` 开发期同样生效；语言切换写系统 `AppleLanguages` 覆盖，重开应用生效。含插值的文案走 `String(format: tr(...))`，语序不同的语言用位置说明符（`%2$@`）调换实参。守门测试保证两表 key 集一致、格式占位符一致、`tr()` 的 key 都在表里、表里没有没人用的 key，界面层与已收口的服务文件没有裸中文字面量。

三处刻意还没双语，源码里各自写了理由与后果：**提示词与模型输入**留中文，所以界面切到英文时 AI 生成的回答仍是中文（要改是整套提示词按语言出版本，并定一条策略：跟界面语言还是跟提问语言）；**中文问句的分词表**（时间词与套话）是解析器而非文案，英文提问现在解析不出时间范围、只会退到默认最近 7 天，那是没做的功能不是漏译；**App Intents 的标题与说明**用 `LocalizedStringResource`，构建期抽进「快捷指令」元数据、取主 bundle 的表，与 `tr()` 的 `Bundle.module` 不是一条路。事件 CLI 与 `LightAnchorEventCore` 是独立 target，没有本地化表，其面向脚本的错误文案留中文。

## 文档地图

| 文档 | 说明 |
| --- | --- |
| [`../AGENTS.md`](../AGENTS.md) | 仓库约定：结构、命令、代码风格、测试与提交要求 |
| [`chat-memory-design.md`](./chat-memory-design.md) | 「对话」页三种记忆与检索的设计与验收标准 |
| [`design/README.md`](./design/README.md) | 界面视觉基准（已冻结，不再更新） |
| [`../Integrations/README.md`](../Integrations/README.md) | 五个工作台接入的协议与手动安装 |
| [`../Support/Brand/BRAND.md`](../Support/Brand/BRAND.md) | 「蜜芽方块」品牌与菜单栏蓝点形态 |

## 第三方素材

- 侧栏导航字形：[Lucide](https://github.com/lucide-icons/lucide)（ISC License，源自 Feather 的部分为 MIT）。只保留实际用到的 SVG，见 [`Support/Icons/lucide/`](../Support/Icons/lucide/)（含 LICENSE 与更新说明）。字形经 `Scripts/import-lucide-glyphs.py` 转成 `Sources/LightAnchor/Design/LightAnchorNavGlyphs.swift`，该文件由脚本生成，勿手改；线宽和颜色由渲染侧给（侧栏 1.75 / 24 网格，单色跟随 `foregroundStyle`）。
- 应用/菜单栏图标（蜜芽方块）与连接页的服务商标识是自绘或各家官方标识，不走本条。
