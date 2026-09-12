# 代码冗余与历史兼容审查

日期：2026-09-11。对象：当前工作区，包含已有未提交修改，不仅是 HEAD。

## 最新确认：发布前只保留当前格式

用户已明确：发布前只有当前这一套软件和数据结构，全部 LightAnchor 本地开发数据都可按需删除。此前人为添加事件版本门槛的处理已撤销，不再要求数据迁移或为保留旧数据调整设计。

- 事件文件只有 `event`，导出文档只有 `events`；移除事件 schema 字段、版本常量、版本探测、拒读门槛及对应文案。
- 发布清单、构建脚本和诊断导出同步去掉事件格式版本。应用版本/构建号、更新签名和发布清单协议校验不是旧数据兼容，继续保留。
- 移除“旧版本应拒读”的测试，改为验证当前结构往返、畸形记录拒读和畸形备份不能替换现有数据/偏好。
- 为“清空后直接重建”增加回归断言，复现并修复磁盘文件删除后事件存储仍缓存旧索引的问题；删除后重新加载空存储，下一次新建不会再尝试删除已不存在的旧文件。
- `AGENTS.md` 已记录发布前数据可删除的授权范围，不再反复索要确认；依然核对应用自有目录、停止写入，不误删源码、原始引用文件或远端数据，不增加启动失败自动删库逻辑。
- 本次无需清空当前正在运行的工作区；重置验证在临时目录进行。

### 当前交付验证

- 全量 `env -u LIGHTANCHOR_SEED_DEMO swift test`：472 项，1 项跳过，0 失败。
- “清空后立即新建”回归先失败、修复索引刷新后通过；新增记录重开工作区后仍可读，旧记录没有回来。
- `Scripts/build-release.sh`、`Scripts/verify-release.sh`、隔离数据的应用烟测和备份烟测均通过；发布 manifest 已确认不含事件格式版本，3 条 App Intents 元数据完整。
- 当前 App：`dist/current/LightAnchor.app`；压缩包：`dist/current/LightAnchor-0.1.0-2026091102-macos.zip`。这是 ad-hoc 签名、未公证的本地测试包，未安装或覆盖正在使用的应用。
- 验证日志：`/tmp/light-anchor-current-format-full.log`、`/tmp/light-anchor-current-format-reset-fixed.log`、`/tmp/light-anchor-current-format-build.log`、`/tmp/light-anchor-current-format-verify.log`、`/tmp/light-anchor-current-format-smoke.log`、`/tmp/light-anchor-current-format-backup.log`。
- 生产构建仍有既存的日期选择器非 Sendable 回调警告，与此次事件格式和重置修复无关。

## 第一批清理结果

状态：已完成并验证。本批针对确定的死代码和历史语义映射，没有进行页面布局重设计，也没有重置或迁移真实用户数据。原有未提交工作保持在工作区，未提交 Git。

### 已完成

- 删除原清单中的 9 处无调用实现：旧邮票阴影、成功按钮样式、折叠组件、回场简报卡、等待改期方法、现场单项删除方法、期限文案组合、快照提交与历史转发。仍被使用的 `ReturnBriefingRows` 保留。
- 删除仅供测试转发的 `dismissTargetDueDate()`，测试改走 `setTargetDueDate(..., to: nil)`；删除没有调用方的 `selectedKinds` 恢复参数与分支。
- 删除 `waiting → paused` 和 `monitor.date → dueAt` 两套解码映射，使用当前模型的合成解码；双语删除失去引用的 `due_by`。
- 已撤销曾添加的事件版本门槛，当前直接按唯一的数据结构读写，具体见开头的最新确认。
- 将工作段与现场配对提取为可直接测试的 `AttentionSnapshot.workSegments(for:)`（`Sources/LightAnchor/Services/WorkHistoryKit.swift:11`）。只认明确匹配的目标与工作段，不把无归属现场猜给最新一段；独立检查点仍合法并保留。
- 现在页恢复时使用所选工作段的现场或其自身上下文，删除会再次查找“目标最新现场”的旧回调，避免绕过精确归属（`Sources/LightAnchor/Views/NowPageView.swift:642`）。
- 替换要求迁移旧状态的测试，补齐当前格式往返、畸形记录拒读且不自动删除、畸形备份拒绝替换、跨工作段现场隔离等回归测试。步骤字段测试改为验证当前独立目标的合法空值，不再承诺旧格式兼容。
- 生产 Swift 源码从 38,301 行降到 38,080 行，净减少 221 行；这是相对本次清理开始时的工作区统计，不是相对 HEAD 的 Git diff。

### 第一批原始验证与产物（已被单一格式修正取代）

- 全量：`env -u LIGHTANCHOR_SEED_DEMO swift test`，472 项，1 项跳过，0 失败。
- 最后调整步骤测试后复测：`swift test --filter 'StepTargetsTests|DueDateTests|WorkHistoryTests|LocalEventStoreLayoutTests|LocalBackupPreferencesTests'`，34 项，0 失败；同样禁用演示播种。
- 生产打包、`Scripts/verify-release.sh`、隔离根目录的应用烟测、`Scripts/smoke-data-backup.sh` 均通过；包内 3 条 App Intents 元数据验证通过，`git diff --check` 通过。
- App：`dist/cleanup-20260911/LightAnchor.app`。
- 压缩包：`dist/cleanup-20260911/LightAnchor-0.1.0-2026091101-macos.zip`。
- 这是当时的 ad-hoc 签名、未公证本地测试包，更新 manifest 未签名；没有安装或覆盖现有应用。这份包仍有已被否定的事件版本门槛，不作为当前交付物。
- 本批没有页面大改；进行了真实 App 启动、关窗重开、深链捕获、自动快照和退出验证，没有进行页面截图验收。
- 编译仍报告已有警告：`LightAnchorTheme` 日期选择器传递非 Sendable 回调，以及部分测试生命周期的 actor 隔离和未使用的 `XCTUnwrap` 返回值。本批没有修改这些逻辑，不宣称构建零警告。
- 日志位于 `/tmp/light-anchor-cleanup-full.log`、`/tmp/light-anchor-cleanup-final-targeted.log`、`/tmp/light-anchor-cleanup-build.log`、`/tmp/light-anchor-cleanup-verify.log`、`/tmp/light-anchor-cleanup-smoke.log` 和 `/tmp/light-anchor-cleanup-backup-smoke.log`。

### 后续独立批次

大文件职责拆分、全量提交的性能测量与增量化、其余源码字符串测试改造仍未实施；隐私偏好的缺字段处理也未草率删除。它们不应混进这批确定性删除，后续需分别验证行为和数据一致性。

复扫还确认 `setTargetDueDate()` 本身目前只有测试和演示播种调用、没有页面入口；本批按原计划仅删除它的薄包装。是否提供用户改期入口应按确认的期限交互处理，不能因测试通过就认为入口已经接好。

以下为**清理前的原始审查记录**，位置与行数对应清理前源码；已解决项以本节为准。

## 结论与范围

- 存在明确的历史兼容分支、失去调用入口的实现，以及职责堆积；不宜把整个项目笼统归为“屎山”。
- 扫描了 83 个生产 Swift 文件，共 38,301 行；重点追踪模型解码、页面入口、主题组件、工作区状态和快照调用链。
- 原始审查按“检查代码、写两条规则”执行；用户随后确认开始清理，执行结果见开头。
- 结论来自静态引用扫描、调用方核查和现有测试。不是完整的编译器可达性分析，也没有做性能压测；以下清单不宣称穷尽所有死代码。
- 优先级：P1 为已发现的语义风险；P2 为明确冗余或维护负担；需要产品判断的项目单独列出。

## 一、历史兼容正在影响新语义

### P1：把旧“提醒时间”解释成新“截止日期”

位置：`Sources/LightAnchor/Domain/AttentionModels.swift:558`，对应测试 `Tests/LightAnchorTests/DueDateTests.swift:202`。

`WaitingItem` 在缺少 `dueAt` 时读取 `LegacyMonitor.date`。但当前模型明确把截止日期定义为“什么时候必须拿到”，旧字段则是“几点再看一眼”。两者不是同一个承诺；加载旧数据后会把一次提醒变成期限，进而影响到期分类和催办。

建议：按新规则删除 `LegacyCodingKeys`、`LegacyMonitor` 和这段字段映射，使用当前模型的解码规则；同步替换要求旧行为继续成立的测试。发布前旧开发数据可按已授权范围清空重建，不另设数据版本门槛，不能用“防止日期丢失”替新模型决定语义。

### P2：已经取消的工作状态仍通过解码存活

位置：`Sources/LightAnchor/Domain/AttentionModels.swift:388`。

当前枚举只有 `active / paused / returning / ended`，但自定义解码仍把旧 `waiting` 映射成 `paused`；上述旧格式测试同时强制保留这条分支。这属于确定的历史兼容，不是当前工作状态必需的逻辑。

建议：移除旧状态映射，恢复当前枚举的合成解码；测试覆盖当前状态往返和不支持状态的明确失败，而不是继续固定旧状态迁移。

### P1：页面把无工作段归属的旧现场挂给最新一段

位置：`Sources/LightAnchor/Views/NowPageView.swift:661`。

`segments(of:)` 找不到精确匹配时，把同目标且 `episodeID == nil` 的现场分配给最新工作段。这不是从事实确认归属：一个较早的现场可能显示在后来新开的一段上，新的一段出现后归属还会变化。

建议：页面只按明确的 `episodeID` 匹配；未知归属的现场保留“未关联”身份，不在视图层猜测迁移。`SceneSnapshot.episodeID` 本身不能据此改成必填：`Sources/LightAnchor/Domain/SceneModels.swift:83` 明确允许没有工作段的检查点现场。

## 二、已核实没有调用入口的代码

以下 9 个实现经生产源码、测试与脚本引用核查，没有实际调用。测试里出现名称的否定字符串断言不算调用；它们也不是系统协议入口。

| 位置 | 实现 | 证据与建议 |
| --- | --- | --- |
| `Sources/LightAnchor/Design/LightAnchorTheme.swift:514` | `lightAnchorStampShadow()` | 邮票设计已取消，只剩定义与测试中的禁用名称；可删除。 |
| `Sources/LightAnchor/Design/LightAnchorTheme.swift:694` | `LightAnchorSuccessButtonStyle` | 没有任何实例化或样式使用；可删除。 |
| `Sources/LightAnchor/Design/LightAnchorTheme.swift:1135` | `LightAnchorDisclosure` | 没有实例化；测试仅要求开始页不再使用它；可删除。 |
| `Sources/LightAnchor/Views/SceneViews.swift:831` | `ReturnBriefingCard` | 没有视图入口；可删除整张旧卡。其内部用的 `ReturnBriefingRows` 仍由 `SceneReturnPanel` 使用，不能连带删除。 |
| `Sources/LightAnchor/App/AttentionWorkspace.swift:723` | `setWaitingDueDate()` | 没有页面或测试调用；若当前设计不需要编辑等待期限，可删除。若需要，则是功能未接入，不能以保留孤立方法算完成。 |
| `Sources/LightAnchor/App/AttentionWorkspace.swift:2312` | `removeSceneItem()` | 注释声称用于确认卡/现场卡，但没有任何调用；应按当前逐条选择行为决定删除，而非相信旧注释。 |
| `Sources/LightAnchor/Views/WorkspacePresentation.swift:172` | `UserFacingCopy.dueLine()` | 没有调用；可删除这层未使用的文案组合。 |
| `Sources/LightAnchor/Services/SnapshotController.swift:121` | `commitSnapshot()` | 注释声称手动按钮走这里，实际按钮直接调用 `snapshotService.snapshot()`；可删除这条重复且吞错的路径。 |
| `Sources/LightAnchor/Services/SnapshotController.swift:131` | `history()` | 控制器实例没有调用此方法；设置页和测试直接调用底层服务的 `history()`，可删除此转发。 |

快照实际入口见 `Sources/LightAnchor/Views/DataManagementView.swift:529` 与 `Sources/LightAnchor/Views/DataManagementView.swift:588`。

### P2：只有测试调用的薄包装

`Sources/LightAnchor/App/AttentionWorkspace.swift:736` 的 `dismissTargetDueDate()` 只把参数转发为 `setTargetDueDate(..., to: nil)`，生产代码没有调用，只有 `DueDateTests` 使用。可去掉包装，让测试直接验证现有入口撤销期限的行为。

这不等于“所有仅测试使用的方法都该删”：例如 `sampleClipboardNow()` 是确定性的采样测试入口，需要保留或用等效测试接口替代。

### P2：旧的按类别恢复参数已不可达

位置：`Sources/LightAnchor/App/AttentionWorkspace.swift:2734`。

`restoreScene()` 同时接受 `selectedKinds` 与 `selectedItemIDs`，但全仓库没有调用方传入 `selectedKinds`。现有重返面板和换事面板都按条目 ID 选择，旧的类别过滤分支只会收到默认 `nil`。

建议：删除 `selectedKinds` 参数和对应过滤分支，保留当前逐条选择的单一路径，并同步修正函数注释。

## 三、职责堆积与不必要的工作量

### P2：三个热点文件集中了约四分之一生产源码

| 文件 | 行数 | 实际混合的职责 | 建议拆分方向 |
| --- | ---: | --- | --- |
| `Sources/LightAnchor/Views/MainWorkspaceView.swift:6` | 4,483 | 窗口布局、导航、搜索建模/展示、稍后清单、多种编辑器、捕获与菜单栏视图 | 按搜索、稍后、捕获、工作编辑等功能模块拆分，主视图保留布局与路由。 |
| `Sources/LightAnchor/App/AttentionWorkspace.swift:5` | 2,822 | 事件提交、目标/工作段、等待/日程、录制、剪贴板、智能输入、现场恢复、数据清理 | 先收敛持久化与状态变更接口，再让功能模块承接自己的输入组装和流程。 |
| `Sources/LightAnchor/Services/IntelligenceKit.swift:31` | 2,850 | 偏好、提供商配置、提示词、离线/端侧/云端引擎、HTTP/SSE、现场构建与失效检查 | 把配置、网络传输、各引擎和现场处理分开，保留真正共用的引擎协议。 |

问题不是行数本身，而是一次页面或能力变更要同时理解多个互不相关的流程。单纯换文件放 `extension`、新增转发层，并不能解决职责和接口过宽的问题。

### P2：每次事件提交仍全量编码、读取和回放

位置：`Sources/LightAnchor/App/AttentionWorkspace.swift:2789`；`Sources/LightAnchor/Services/LocalEventStore.swift:160`。

虽然事件已经改成逐文件增量写入，但每次 `commit()` 仍把全部事件交给 `save()` 重新编码比较，随后 `load()` 读取全部文件并全量回放；提交运行于 `@MainActor` 的工作区。数据越多，一次小操作就要做越多历史工作。

这是可从代码确定的 O(N) 历史遍历，不是已经测得的卡顿结论。建议先用增长中的事件集测量提交耗时，再让普通追加只处理新事件；全量回放留给启动、恢复和同步。重构必须保留写入失败时的状态一致性和隐私删除路径，不能直接删掉校验或回读就宣称完成优化。

### P2：测试把旧外观和代码拼写固定下来

位置：`Tests/LightAnchorTests/BlueDotAuditTests.swift:213`、`Tests/LightAnchorTests/BlueDotAuditTests.swift:231`。

测试通过 `source.contains(...)` 固定某些组件名、源码切片和布局片段，甚至断言 `height: blockHeight` 正好出现四次。这样重构或新设计确认后容易被旧测试反向约束，且检查某个页面不使用旧样式，并不能阻止旧样式仍留在主题文件中。

建议：保留有价值的可访问性、隐私和导航不变量；已被新确认设计取代的外观约束应直接更新或删除。核心交互通过行为测试验证，视觉通过截图验收，避免为了让旧字符串断言通过而保留废代码。

## 四、不要误删的代码与待判断项

- `MemoryIndexKit.migrateIfNeeded()` 实际主要做建表、缓存失效和模型切换后的向量重建（`Sources/LightAnchor/Services/MemoryIndexKit.swift:483`），不是旧业务模型迁移层。名称可在相关重构中改准，缓存失效机制不能因出现 migrate 就删除。
- `FoundationModels` 的 macOS 26 可用性检查服务于当前 macOS 15 最低要求；OpenAI/Anthropic 等协议适配服务于正在支持的提供商，不属于为了旧产品设计保留的历史兼容。
- AppKit 生命周期回调、`FileDocument.fileWrapper`、`URLSessionTaskDelegate` 方法、App Intents/Shortcuts 类型由框架调用或发现，不能按“源码只出现一次”判死。
- Optional 字段有真实业务语义，例如未生成的总结、无期限等待和独立检查点；可合成解码并不意味着是在保留兼容层。
- `IntelligencePreferences.init(from:)`（`Sources/LightAnchor/Services/IntelligenceKit.swift:410`）对缺字段逐项回落默认值，应明确当前格式是否允许部分配置。若只是为了旧偏好就应去掉；如果删掉后整包重置会放宽用户隐私设置，则要先设计明确的失败处理，不能简单恢复默认。
- 本地化测试检查了双语 key 一致和文本引用，但无法识别“引用它的整个组件已经死掉”；删除已确认的死组件后应再清理仅属于它的双语文案，不能凭关键词先删表。

## 建议执行顺序

1. 删除确认无调用的旧组件、转发方法和 `selectedKinds` 分支；同步清理失效文案和注释，运行测试。
2. 删除旧等待/期限/现场映射及其迁移测试；只维护当前结构，必要时按发布前授权清空本地开发数据。
3. 按功能模块拆分热点，单独验证提交性能与状态一致性，不把清理变成整仓重写。
4. 若后续改动涉及页面结构、导航、主要交互或大面积视觉调整，按 `AGENTS.md` 自动打包、验包、隔离烟测并交付新包。

## 原始审查验证

- 命令：`env -u LIGHTANCHOR_SEED_DEMO swift test`，显式禁用演示数据播种。
- 结果：465 项测试，1 项跳过，0 失败；测试执行约 55 秒。
- 日志：`/tmp/light-anchor-code-audit-swift-test-2026-09-11.log`。
- 原始审查只改规则与报告，因此当时未打包；后续清理已生成新包，见开头的验证与产物。
