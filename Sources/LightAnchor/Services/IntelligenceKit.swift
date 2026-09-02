// MARK: - 智能引擎
//
// 提示词与喂给模型的事实标签（「目标：」「现场的文件：」等）刻意留在中文，
// 不进本地化表：它们不是界面文案，而是模型的输入语言。当前的后果是明确的——
// 界面切到英文时，AI 生成的回答仍然是中文。要改是一件独立的事（整套提示词
// 按语言各出一版，并挑一条策略：跟界面语言，还是跟提问语言），不是补几个 key。

import AppKit
import Foundation

// LIGHTANCHOR_DISABLE_FOUNDATIONMODELS：只装 Command Line Tools 的机器缺
// FoundationModels 的宏插件（@Generable 展不开），加
// `-Xswiftc -DLIGHTANCHOR_DISABLE_FOUNDATIONMODELS` 可关掉端侧引擎照常构建；
// Xcode / CI 不受影响。
#if canImport(FoundationModels) && !LIGHTANCHOR_DISABLE_FOUNDATIONMODELS
import FoundationModels
#endif

// MARK: - IntelligenceKit
//
// 智能层。设计原则：
// 1. 云端增强是主路径，端侧与确定性规则作为本机兜底。
// 2. 无 AI 可用时降级为确定性的事实拼装——不猜测：判断类能力（相关性/去向）
//    如实报「无法判断」，由调用方落到全部保留/先留着。
// 3. 所有推断可关闭，提供事实依据。
// 4. AI 只负责翻译/建议，不替用户决定。

// MARK: - 偏好

/// 智能引擎选择。
enum IntelligenceEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case onDevice
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: tr("on_device")
        case .cloud: tr("cloud")
        }
    }
}

/// 云端请求协议。端点只是地址，协议决定请求体、认证头和响应解析方式。
enum CloudAPIProtocol: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openAIChatCompletions
    case openAIResponses
    case anthropicMessages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAIChatCompletions: "OpenAI Chat Completions"
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        }
    }

    var shortTitle: String {
        switch self {
        case .openAIChatCompletions: "OpenAI Chat"
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic"
        }
    }
}

enum CloudServicePreset: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openAI
    case anthropic
    case deepSeek
    case openRouter
    case siliconFlow
    case moonshot
    case groq
    case together
    case gemini
    case ollama
    case lmStudio
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic / Claude"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .siliconFlow: tr("siliconflow")
        case .moonshot: "Moonshot / Kimi"
        case .groq: "Groq"
        case .together: "Together AI"
        case .gemini: "Google Gemini"
        case .ollama: tr("ollama_local")
        case .lmStudio: tr("lm_studio_local")
        case .custom: tr("custom_compatible_service")
        }
    }

    var chatEndpoint: String? {
        switch self {
        case .openAI: "https://api.openai.com/v1/chat/completions"
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .deepSeek: "https://api.deepseek.com/v1/chat/completions"
        case .openRouter: "https://openrouter.ai/api/v1/chat/completions"
        case .siliconFlow: "https://api.siliconflow.cn/v1/chat/completions"
        case .moonshot: "https://api.moonshot.cn/v1/chat/completions"
        case .groq: "https://api.groq.com/openai/v1/chat/completions"
        case .together: "https://api.together.xyz/v1/chat/completions"
        // Gemini 走官方 OpenAI 兼容层，避免为它单开一种协议。
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .ollama: "http://localhost:11434/v1/chat/completions"
        case .lmStudio: "http://localhost:1234/v1/chat/completions"
        case .custom: nil
        }
    }

    var modelsEndpoint: String? {
        switch self {
        case .openAI: "https://api.openai.com/v1/models"
        case .anthropic: "https://api.anthropic.com/v1/models"
        case .deepSeek: "https://api.deepseek.com/v1/models"
        case .openRouter: "https://openrouter.ai/api/v1/models"
        case .siliconFlow: "https://api.siliconflow.cn/v1/models"
        case .moonshot: "https://api.moonshot.cn/v1/models"
        case .groq: "https://api.groq.com/openai/v1/models"
        case .together: "https://api.together.xyz/v1/models"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai/models"
        case .ollama: "http://localhost:11434/v1/models"
        case .lmStudio: "http://localhost:1234/v1/models"
        case .custom: nil
        }
    }

    var defaultModel: String? {
        switch self {
        case .openAI: "gpt-5.6-luna"
        case .anthropic: "claude-sonnet-5"
        case .deepSeek: "deepseek-chat"
        case .openRouter: "openai/gpt-5-mini"
        case .siliconFlow: "Qwen/Qwen3-30B-A3B"
        case .moonshot: "kimi-k2.5"
        case .groq: "llama-3.3-70b-versatile"
        case .together: "openai/gpt-oss-120b"
        case .gemini: "gemini-2.5-flash"
        // 本地服务装了什么模型只有本机知道：连上后从列表里选。
        case .ollama: nil
        case .lmStudio: nil
        case .custom: nil
        }
    }

    var recommendedModels: [String] {
        switch self {
        case .openAI:
            ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5-mini", "gpt-4.1-mini", "gpt-4o-mini"]
        case .anthropic:
            ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5"]
        case .deepSeek:
            ["deepseek-chat", "deepseek-reasoner"]
        case .openRouter:
            ["openai/gpt-5-mini", "anthropic/claude-sonnet-4.5", "google/gemini-2.5-flash"]
        case .siliconFlow:
            ["Qwen/Qwen3-30B-A3B", "deepseek-ai/DeepSeek-V3", "Qwen/Qwen2.5-72B-Instruct"]
        case .moonshot:
            ["kimi-k2.5", "kimi-k2"]
        case .groq:
            ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "qwen/qwen3-32b"]
        case .together:
            ["openai/gpt-oss-120b", "meta-llama/Llama-3.3-70B-Instruct-Turbo", "Qwen/Qwen2.5-72B-Instruct-Turbo"]
        case .gemini:
            ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite"]
        case .ollama, .lmStudio, .custom:
            []
        }
    }

    var defaultAPIProtocol: CloudAPIProtocol {
        switch self {
        case .anthropic: .anthropicMessages
        default: .openAIChatCompletions
        }
    }

    var supportedAPIProtocols: [CloudAPIProtocol] {
        switch self {
        case .openAI: [.openAIChatCompletions, .openAIResponses]
        case .anthropic: [.anthropicMessages]
        case .custom: CloudAPIProtocol.allCases
        default: [.openAIChatCompletions]
        }
    }

    func endpoint(for apiProtocol: CloudAPIProtocol) -> String? {
        switch (self, apiProtocol) {
        case (.openAI, .openAIResponses): "https://api.openai.com/v1/responses"
        case (.anthropic, .anthropicMessages): "https://api.anthropic.com/v1/messages"
        default: chatEndpoint
        }
    }
}

/// 一套完整、可命名、可切换的云端供应商配置（「配置方案」）。
///
/// 方案是云端配置的唯一事实源。上一版把「当前云端字段」和「已存方案」并列，
/// 于是列表里要摆一个「未保存的配置」幽灵项，新建第二套还得先改坏第一套；
/// 现在设置页编辑的就是方案本身，选中即使用中，只有一套状态。
struct CloudProviderProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var provider: CloudServicePreset
    var apiProtocol: CloudAPIProtocol
    /// API Key 允许为空。本地服务、公司网关、免鉴权反代都可能不需要 Key：
    /// 空 Key 只是不发认证头，不算配置不完整，也不拦「测试连接」。
    ///
    /// 只住在内存里：编码时默认不写出（见 `encode(to:)`），持久化由
    /// `IntelligencePreferences.save` 单独交给 `CloudAPIKeyStore`（钥匙串）。
    var apiKey: String
    var chatEndpoint: String
    var model: String

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, apiProtocol, apiKey, chatEndpoint, model
    }

    /// 编码器 userInfo 里放 true 才把 Key 一起写出。默认不写：偏好 blob 会进
    /// 备份 zip、也曾明文躺在 UserDefaults 里，Key 不该跟着走。
    static let encodeAPIKeyUserInfoKey = CodingUserInfoKey(rawValue: "com.lightanchor.encodeAPIKey")!

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        provider = try container.decode(CloudServicePreset.self, forKey: .provider)
        apiProtocol = try container.decode(CloudAPIProtocol.self, forKey: .apiProtocol)
        // 老 blob 里还带着 Key（迁移前的数据）：照读，由 load 搬进钥匙串。
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        chatEndpoint = try container.decode(String.self, forKey: .chatEndpoint)
        model = try container.decode(String.self, forKey: .model)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(provider, forKey: .provider)
        try container.encode(apiProtocol, forKey: .apiProtocol)
        if encoder.userInfo[Self.encodeAPIKeyUserInfoKey] as? Bool == true {
            try container.encode(apiKey, forKey: .apiKey)
        }
        try container.encode(chatEndpoint, forKey: .chatEndpoint)
        try container.encode(model, forKey: .model)
    }

    init(
        id: UUID = UUID(),
        name: String,
        provider: CloudServicePreset,
        apiProtocol: CloudAPIProtocol,
        apiKey: String,
        chatEndpoint: String,
        model: String
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiProtocol = apiProtocol
        self.apiKey = apiKey
        self.chatEndpoint = chatEndpoint
        self.model = model
    }

    /// 按预设服务生成一套填好的新方案：协议、端点、默认模型都随服务带上，
    /// 名字与已有方案去重。新建不再复制「当前字段」，所以加第二套配置时
    /// 第一套一个字都不会动。
    static func make(
        provider: CloudServicePreset,
        existingNames: Set<String> = []
    ) -> CloudProviderProfile {
        let apiProtocol = provider.defaultAPIProtocol
        let model = provider.defaultModel ?? ""
        return CloudProviderProfile(
            name: uniqueName(base: defaultName(provider: provider), existingNames: existingNames),
            provider: provider,
            apiProtocol: apiProtocol,
            apiKey: "",
            chatEndpoint: provider.endpoint(for: apiProtocol) ?? "",
            model: model
        )
    }

    /// 复制一套方案（含 Key）：同一家服务换个模型是最常见的第二套配置。
    /// Key 随内存副本一起带到新 id 上，`IntelligencePreferences.save` 时按新 id
    /// 写进钥匙串。
    func duplicated(existingNames: Set<String>) -> CloudProviderProfile {
        var copy = self
        copy.id = UUID()
        copy.name = Self.uniqueName(base: name, existingNames: existingNames)
        return copy
    }

    /// 自动名只用服务名。清单行的副标题已经在说地址和模型了，名字再重复一遍
    /// 只会让两行长得一样。
    static func defaultName(provider: CloudServicePreset) -> String {
        provider.title
    }

    static func uniqueName(base: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(base) else { return base }
        var counter = 2
        while existingNames.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    /// 实际发出请求的端点：用户填的可能只是基地址（各家文档给的就是基地址），
    /// 缺的那段请求路径由我们补齐，而不是让用户拿一个 404 去猜。
    var resolvedChatEndpoint: String {
        CloudConnectionConfiguration.completedRequestEndpoint(chatEndpoint, for: apiProtocol)
    }

    /// 实际用于「连接并获取模型」的列表端点。预设服务用官方地址；
    /// 自定义/改过请求端点时从请求端点推导，不再单独让用户填。
    var effectiveModelsEndpoint: String {
        if provider != .custom, let preset = provider.modelsEndpoint {
            return preset
        }
        return CloudConnectionConfiguration.deriveModelsEndpoint(
            fromChatEndpoint: resolvedChatEndpoint
        ) ?? ""
    }

    var connection: CloudConnectionConfiguration {
        CloudConnectionConfiguration(
            apiKey: apiKey,
            chatEndpoint: resolvedChatEndpoint,
            modelsEndpoint: effectiveModelsEndpoint,
            model: model
        )
    }

    var status: CloudConfigurationStatus { connection.status }

    /// 清单行副标题：连到哪台主机、用哪个模型——名字之外真正需要看见的两件事。
    var summary: String {
        let host = CloudConnectionConfiguration.url(from: chatEndpoint)?.host ?? ""
        let parts = [host, model].filter { !$0.isEmpty }
        return parts.isEmpty ? provider.title : parts.joined(separator: " · ")
    }
}

/// 智能功能开关集合。每项独立可控。
struct IntelligencePreferences: Codable, Equatable, Sendable {
    var engine: IntelligenceEngine
    var sceneFilterDefault: SceneFilterMode
    var saveTerminalCommands: Bool
    var saveClipboardContent: Bool
    var saveWindowScreenshot: Bool
    var generateReturnCue: Bool
    var checkSceneStaleness: Bool
    var inboxAutoOrganize: Bool
    /// ADHD 友好输出：所有 AI 生成的文字按 i-have-adhd 技能塑形
    /// （行动放最前、多步编号、具体数字、无铺垫客套）。默认开。
    var adhdFriendlyOutput: Bool
    /// 跟随工作自动录制过程：开始一件事就起一份过程记录，放下暂停、
    /// 结束收尾。默认关——录制是扩展能力，不改变既有流程。
    var autoRecordEpisodes: Bool
    /// 云端配置方案。列表顺序即界面顺序，初始化时保证至少有一套。
    var cloudProfiles: [CloudProviderProfile]
    /// 使用中的方案。设置页里「选中」和「使用中」是同一件事，
    /// 所以这里始终指向 cloudProfiles 中真实存在的一套。
    var activeCloudProfileID: UUID

    static let storageKey = "intelligence.preferences"

    static let `default` = IntelligencePreferences(
        engine: .cloud,
        sceneFilterDefault: .aiFiltered,
        saveTerminalCommands: true,
        // 剪贴板最容易装下别人的信息（密码、他人的消息）：默认不存，用户自己开。
        saveClipboardContent: false,
        saveWindowScreenshot: false,
        generateReturnCue: true,
        checkSceneStaleness: true,
        inboxAutoOrganize: false,
        adhdFriendlyOutput: true
    )

    init(
        engine: IntelligenceEngine,
        sceneFilterDefault: SceneFilterMode,
        saveTerminalCommands: Bool,
        saveClipboardContent: Bool,
        saveWindowScreenshot: Bool,
        generateReturnCue: Bool,
        checkSceneStaleness: Bool,
        inboxAutoOrganize: Bool,
        adhdFriendlyOutput: Bool = true,
        autoRecordEpisodes: Bool = false,
        cloudProfiles: [CloudProviderProfile] = [],
        activeCloudProfileID: UUID? = nil
    ) {
        self.engine = engine
        self.sceneFilterDefault = sceneFilterDefault
        self.saveTerminalCommands = saveTerminalCommands
        self.saveClipboardContent = saveClipboardContent
        self.saveWindowScreenshot = saveWindowScreenshot
        self.generateReturnCue = generateReturnCue
        self.checkSceneStaleness = checkSceneStaleness
        self.inboxAutoOrganize = inboxAutoOrganize
        self.adhdFriendlyOutput = adhdFriendlyOutput
        self.autoRecordEpisodes = autoRecordEpisodes
        // 不变量在这里立起来：至少一套方案，且使用中的那套一定在列表里。
        // 否则「云端」引擎会指向一套不存在的配置，界面也没有可选中的行。
        let normalized = cloudProfiles.isEmpty
            ? [CloudProviderProfile.make(provider: .openAI)]
            : cloudProfiles
        self.cloudProfiles = normalized
        self.activeCloudProfileID = normalized.contains { $0.id == activeCloudProfileID }
            ? activeCloudProfileID!
            : normalized[0].id
    }

    private enum CodingKeys: String, CodingKey {
        case engine, sceneFilterDefault, saveTerminalCommands, saveClipboardContent
        case saveWindowScreenshot, generateReturnCue, checkSceneStaleness, inboxAutoOrganize
        case adhdFriendlyOutput, autoRecordEpisodes
        case cloudProfiles, activeCloudProfileID
    }

    /// 0.1.0 的扁平云端字段：只有一套配置，没有方案列表。只读、不再写回。
    private enum LegacyCloudKeys: String, CodingKey {
        case cloudProvider, cloudProtocol, cloudAPIKey, cloudChatEndpoint, cloudModel
    }

    /// 宽容解码：老数据缺新字段时逐项落回默认值，不整包作废用户配置。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        var profiles = try container.decodeIfPresent([CloudProviderProfile].self, forKey: .cloudProfiles)
            ?? []
        if profiles.isEmpty,
           let legacy = try? decoder.container(keyedBy: LegacyCloudKeys.self),
           let migrated = Self.migratedCloudProfile(from: legacy) {
            profiles = [migrated]
        }
        self.init(
            engine: try container.decodeIfPresent(IntelligenceEngine.self, forKey: .engine)
                ?? fallback.engine,
            sceneFilterDefault: try container.decodeIfPresent(SceneFilterMode.self, forKey: .sceneFilterDefault)
                ?? fallback.sceneFilterDefault,
            saveTerminalCommands: try container.decodeIfPresent(Bool.self, forKey: .saveTerminalCommands)
                ?? fallback.saveTerminalCommands,
            saveClipboardContent: try container.decodeIfPresent(Bool.self, forKey: .saveClipboardContent)
                ?? fallback.saveClipboardContent,
            saveWindowScreenshot: try container.decodeIfPresent(Bool.self, forKey: .saveWindowScreenshot)
                ?? fallback.saveWindowScreenshot,
            generateReturnCue: try container.decodeIfPresent(Bool.self, forKey: .generateReturnCue)
                ?? fallback.generateReturnCue,
            checkSceneStaleness: try container.decodeIfPresent(Bool.self, forKey: .checkSceneStaleness)
                ?? fallback.checkSceneStaleness,
            inboxAutoOrganize: try container.decodeIfPresent(Bool.self, forKey: .inboxAutoOrganize)
                ?? fallback.inboxAutoOrganize,
            adhdFriendlyOutput: try container.decodeIfPresent(Bool.self, forKey: .adhdFriendlyOutput)
                ?? fallback.adhdFriendlyOutput,
            autoRecordEpisodes: try container.decodeIfPresent(Bool.self, forKey: .autoRecordEpisodes)
                ?? fallback.autoRecordEpisodes,
            cloudProfiles: profiles,
            activeCloudProfileID: try container.decodeIfPresent(UUID.self, forKey: .activeCloudProfileID)
        )
    }

    /// 把 0.1.0 那套扁平配置搬成一套命名方案。升级不能把用户填过的 Key
    /// 和端点吞掉——只要老数据里出现过任一个云端字段就搬。
    private static func migratedCloudProfile(
        from container: KeyedDecodingContainer<LegacyCloudKeys>
    ) -> CloudProviderProfile? {
        let touched = [LegacyCloudKeys.cloudProvider, .cloudProtocol, .cloudAPIKey,
                       .cloudChatEndpoint, .cloudModel]
        guard touched.contains(where: container.contains) else { return nil }

        let provider = (try? container.decodeIfPresent(CloudServicePreset.self, forKey: .cloudProvider))
            .flatMap { $0 } ?? .openAI
        let apiProtocol = (try? container.decodeIfPresent(CloudAPIProtocol.self, forKey: .cloudProtocol))
            .flatMap { $0 } ?? provider.defaultAPIProtocol
        let apiKey = (try? container.decodeIfPresent(String.self, forKey: .cloudAPIKey))
            .flatMap { $0 } ?? ""
        let chatEndpoint = (try? container.decodeIfPresent(String.self, forKey: .cloudChatEndpoint))
            .flatMap { $0 } ?? provider.endpoint(for: apiProtocol) ?? ""
        let model = (try? container.decodeIfPresent(String.self, forKey: .cloudModel))
            .flatMap { $0 } ?? provider.defaultModel ?? ""

        return CloudProviderProfile(
            name: CloudProviderProfile.defaultName(provider: provider),
            provider: provider,
            apiProtocol: apiProtocol,
            apiKey: apiKey,
            chatEndpoint: chatEndpoint,
            model: model
        )
    }

    // MARK: - 配置方案

    /// 使用中的那套方案。读取总有结果；写入只落在同 id 的那套上。
    var activeCloudProfile: CloudProviderProfile {
        get {
            cloudProfiles.first { $0.id == activeCloudProfileID }
                ?? cloudProfiles.first
                ?? CloudProviderProfile.make(provider: .openAI)
        }
        set {
            guard let index = cloudProfiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            cloudProfiles[index] = newValue
        }
    }

    var cloudProfileNames: Set<String> {
        Set(cloudProfiles.map(\.name))
    }

    /// 切换到某套方案。这是「配置好后直接切换」的全部动作：不复制、不回写。
    mutating func selectCloudProfile(id: UUID) {
        guard cloudProfiles.contains(where: { $0.id == id }) else { return }
        activeCloudProfileID = id
    }

    /// 新建一套预设服务的方案，并切换过去。返回新方案的 id。
    @discardableResult
    mutating func addCloudProfile(provider: CloudServicePreset) -> UUID {
        let profile = CloudProviderProfile.make(provider: provider, existingNames: cloudProfileNames)
        cloudProfiles.append(profile)
        activeCloudProfileID = profile.id
        return profile.id
    }

    /// 复制使用中的方案（含 Key），并切换过去。
    @discardableResult
    mutating func duplicateActiveCloudProfile() -> UUID {
        let copy = activeCloudProfile.duplicated(existingNames: cloudProfileNames)
        cloudProfiles.append(copy)
        activeCloudProfileID = copy.id
        return copy.id
    }

    /// 删除一套方案。最后一套不删：云端引擎必须始终有一套配置可指。
    /// 删掉使用中的那套时接住相邻一套，界面不会落到空选中。
    mutating func removeCloudProfile(id: UUID) {
        guard cloudProfiles.count > 1,
              let index = cloudProfiles.firstIndex(where: { $0.id == id }) else { return }
        cloudProfiles.remove(at: index)
        if activeCloudProfileID == id {
            activeCloudProfileID = cloudProfiles[min(index, cloudProfiles.count - 1)].id
        }
    }

    /// 删除全部本地数据时调用：抹掉用户填过的云端凭据与端点，保留采集与输出
    /// 开关。整块删掉这个 blob 会把「不保存剪贴板」「不保存窗口截图」这类
    /// 收紧过的隐私开关退回默认（默认更宽松），那不是用户点「删除」时要的。
    static func eraseCloudConfiguration(in defaults: UserDefaults = .standard) {
        var preferences = load(from: defaults)
        let fresh = CloudProviderProfile.make(provider: .openAI)
        preferences.cloudProfiles = [fresh]
        preferences.activeCloudProfileID = fresh.id
        // 钥匙串里的每一把 Key 都是用户凭据：整个清空，不只清方案列表里的。
        CloudAPIKeyStore.shared.removeAll()
        preferences.save(to: defaults)
    }

    /// 读偏好，并把每套方案的 Key 从钥匙串补回内存。
    ///
    /// 迁移：blob 里若还带着 Key（钥匙串之前的版本存的），先搬进钥匙串，再
    /// 立刻把不含 Key 的 blob 写回——用户升级后第一次启动，明文就从磁盘上消失。
    /// 0.1.0 的扁平字段（`cloudAPIKey`）也走同一条路：`init(from:)` 把它拼成
    /// 一套带 Key 的方案，这里一并搬走。
    static func load(from defaults: UserDefaults = .standard) -> IntelligencePreferences {
        guard let data = defaults.data(forKey: storageKey),
              var preferences = try? JSONDecoder().decode(IntelligencePreferences.self, from: data) else {
            return .default
        }
        let store = CloudAPIKeyStore.shared
        var blobCarriedKeys = false
        for index in preferences.cloudProfiles.indices {
            let profile = preferences.cloudProfiles[index]
            if !profile.apiKey.isEmpty {
                store.setKey(profile.apiKey, for: profile.id)
                blobCarriedKeys = true
            } else if let stored = store.key(for: profile.id) {
                preferences.cloudProfiles[index].apiKey = stored
            }
        }
        if blobCarriedKeys {
            preferences.save(to: defaults)
        }
        return preferences
    }

    /// 存偏好：Key 逐把进钥匙串，blob 里不留 Key。
    ///
    /// 被删掉的方案（上一份 blob 里有、这一份没有）的 Key 一并从钥匙串清掉，
    /// 不让孤儿凭据越攒越多。只跟同一个 UserDefaults 里的上一份比：多个
    /// defaults 域共用一个钥匙串时（测试就是），互不误删。
    func save(to defaults: UserDefaults = .standard) {
        let store = CloudAPIKeyStore.shared
        let currentIDs = Set(cloudProfiles.map(\.id))
        if let previousData = defaults.data(forKey: Self.storageKey),
           let previous = try? JSONDecoder().decode(IntelligencePreferences.self, from: previousData) {
            for dropped in previous.cloudProfiles where !currentIDs.contains(dropped.id) {
                store.setKey(nil, for: dropped.id)
            }
        }
        for profile in cloudProfiles {
            store.setKey(profile.apiKey, for: profile.id)
        }
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - 能力协议

/// 智能引擎能力。
protocol IntelligenceEngineProtocol: Sendable {
    var name: String { get }
    var isAvailable: Bool { get }

    /// 判断现场条目是否与目标相关。返回每条的相关性 + 理由。
    /// 实现必须保证：返回数量与输入一致、itemID 一一对应；失败时返回空数组由调用方降级。
    func filterSceneItems(
        items: [SceneItem],
        targetName: String,
        targetNote: String
    ) async -> [SceneRelevanceResult]

    /// 生成「回来先做」一行。
    func generateReturnCue(
        items: [SceneItem],
        targetName: String,
        lastEditedFile: String?,
        lastTerminalCommand: String?
    ) async -> String

    /// 回场简报：离开归来时的三行「你在哪 / 发生了什么 / 先做什么」。
    func generateReturnBriefing(_ input: ReturnBriefingInput) async -> ReturnBriefing?

    /// 收件箱清理台：逐条提议去向；只提议，不执行。
    /// 实现必须保证返回的 captureID 都来自输入。
    func triageInbox(
        items: [InboxTriageItem],
        recentTargets: [String]
    ) async -> [InboxTriageProposal]

    /// 叙事回顾：把一个周期的事实写成一段平实的中文。只用给定事实。
    func generateNarrative(_ input: NarrativeInput) async -> String?

    /// 问记忆：依据检索出的事实行回答一个自然语言问题（「对话」页）。
    /// 与其他能力不同：不可用或失败时必须抛错（带上服务端原文），
    /// 由调用方把错误原样亮给用户——不做任何静默兜底或冒名降级（用户定）。
    func answerMemoryQuestion(_ input: MemoryQuestionInput) async throws -> String

    /// 问记忆（流式）：每个元素是「到目前为止的完整回答」（累积文本，不是增量）——
    /// 端侧模型只给累积快照，统一成累积语义所有引擎才能共用一个消费端。
    /// 错误语义与 answerMemoryQuestion 相同：失败在流内抛出、不兜底；
    /// 消费端取消 Task 即中断请求。
    func streamMemoryAnswer(_ input: MemoryQuestionInput) -> AsyncThrowingStream<String, Error>

    /// 检索前的追问改写（RAG 标准步骤）：把「那件事呢」按对话历史补全成
    /// 独立可检索的问题。锦上添花语义：不可用/失败一律返回 nil，检索用原句。
    func rewriteMemoryQuery(question: String, history: [MemoryChatTurn]) async -> String?

    /// 整理记录：把用户的原始草稿整理成 Markdown 成稿（分享文档或 SKILL.md）。
    /// 错误语义与 answerMemoryQuestion 相同：这是用户主动点的动作，
    /// 失败必须抛错亮给用户，不做冒名降级——启发式引擎的确定性拼装除外
    /// （它本身就署名「启发式（离线）」，输出是透明的规则结果）。
    func composeRecordMarkdown(_ input: RecordComposeInput) async throws -> String
}

extension IntelligenceEngineProtocol {
    /// 不具备改写能力的引擎的默认实现：不改写。
    func rewriteMemoryQuery(question: String, history: [MemoryChatTurn]) async -> String? {
        nil
    }
}

extension IntelligenceEngineProtocol {
    /// 不支持流式的引擎的默认实现：完整回答一次性产出。
    func streamMemoryAnswer(_ input: MemoryQuestionInput) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let answer = try await answerMemoryQuestion(input)
                    continuation.yield(answer)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 问记忆的引擎错误：不可用也要说清楚是为什么。
enum MemoryAnswerError: LocalizedError, Equatable {
    case engineUnavailable(String)
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let detail): detail
        case .emptyAnswer: tr("the_model_returned_nothing_please_retry")
        }
    }
}

// MARK: - 回场简报

/// 回场简报的输入：全部来自本地事实，不含任何内容正文。
struct ReturnBriefingInput: Sendable, Equatable {
    var targetName: String
    var targetNote: String
    var returnCue: String
    /// 离开分钟数（0 表示未知）。
    var awayMinutes: Int
    /// 从等待回来时的结果证据；直接切回来时为空。
    var waitingEvidence: String
    var sceneItems: [SceneItem]
    /// 离开期间捕获的内容（每条一行摘要）。
    var capturesWhileAway: [String]
    /// 这件事的历史纵深一句话（累计时长/段数/上次），来自 MemoryRecall；可为空。
    var targetHistoryLine: String = ""
}

struct ReturnBriefing: Sendable, Equatable {
    var whereYouWere: String
    var whatHappened: String
    var firstStep: String
}

// MARK: - 收件箱清理台

enum InboxTriageAction: String, Sendable, CaseIterable, Identifiable {
    case startTarget
    case convertToWaiting
    case saveReference
    case archive
    case keep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startTarget: tr("make_it_a_task")
        case .convertToWaiting: tr("turn_into_a_wait")
        case .saveReference: tr("file_as_reference")
        case .archive: tr("archive")
        case .keep: tr("keep_in_inbox")
        }
    }
}

/// 清理台的输入条目（内容截断到摘要级）。
struct InboxTriageItem: Sendable, Equatable {
    let captureID: UUID
    let kind: CaptureKind
    let summary: String
    let ageDays: Int
    let tags: [String]
    /// 历史去向提示（「过去 30 天同域名 5 条：4 条存了资料」），可为空。
    var historyHint: String = ""
}

struct InboxTriageProposal: Sendable, Equatable, Identifiable {
    let captureID: UUID
    let action: InboxTriageAction
    let reason: String

    var id: UUID { captureID }
}

// MARK: - 叙事回顾

/// 叙事输入：周期标题 + 一组事实句（模型只许复述这些）。
struct NarrativeInput: Sendable, Equatable {
    var periodTitle: String
    var factLines: [String]
}

/// 单条现场条目的相关性判断结果。
struct SceneRelevanceResult: Sendable, Equatable {
    let itemID: UUID
    let isRelevant: Bool
    let reason: String
}

// MARK: - 问记忆

/// 一轮此前的问答原文。多轮上下文按角色原样传给引擎，
/// 不再折叠成 60/80 字的摘录行——追问要接得上，上文就得是真的上文。
struct MemoryChatTurn: Sendable, Equatable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    var role: Role
    var text: String
}

/// 「问记忆」的输入：问题 + 检索出的事实行 + 此前问答（供「那件事呢」式追问衔接）。
/// 事实行来自 MemoryRecall，全部是本地记录；模型只许复述它们。
/// history 由引擎自行裁剪（云端发成真正的 messages 数组，端侧折叠进提示词）。
struct MemoryQuestionInput: Sendable, Equatable {
    var question: String
    var periodTitle: String
    var factLines: [String]
    var history: [MemoryChatTurn]

    init(question: String, periodTitle: String, factLines: [String], history: [MemoryChatTurn] = []) {
        self.question = question
        self.periodTitle = periodTitle
        self.factLines = factLines
        self.history = history
    }
}

// MARK: - 整理过程记录

/// 整理过程记录的输入：标题 + 风格 + 软件记录的过程事实行（时间顺序）。
/// 事实行来自录制 trace，全部是本机观察到的事实；模型只许依据它们。
struct RecordComposeInput: Sendable, Equatable {
    var title: String
    var style: RecordingStyle
    var factLines: [String]
}

// MARK: - 提示词构造（引擎间共享）

enum IntelligencePrompts {
    static func sceneFilterUser(items: [SceneItem], targetName: String, targetNote: String) -> String {
        var lines: [String] = []
        lines.append("当前目标：\(targetName)")
        if !targetNote.isEmpty {
            lines.append("目标说明：\(targetNote)")
        }
        lines.append("现场条目：")
        for (index, item) in items.enumerated() {
            var parts = ["\(index + 1). [\(item.kind.title)] \(item.title)"]
            if !item.sourceApplication.isEmpty {
                parts.append("来自 \(item.sourceApplication)")
            }
            if !item.detail.isEmpty {
                parts.append("（\(item.detail)）")
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    static let sceneFilterInstructions = """
        你是现场筛选助手。用户正在专注于一个目标，系统记录了当前屏幕上的文件、网页、终端和应用。
        判断每一条是否与该目标相关。判断依据：文件名/网页标题与目标主题的语义关系、应用用途。
        通信、娱乐、系统类应用默认无关，除非目标明确提到。理由用一句简短中文。
        """

    static func returnCueUser(
        items: [SceneItem],
        targetName: String,
        lastEditedFile: String?,
        lastTerminalCommand: String?
    ) -> String {
        var lines: [String] = ["目标：\(targetName)"]
        if let file = lastEditedFile {
            lines.append("最后在编辑的文件：\(file)")
        }
        if let cmd = lastTerminalCommand, !cmd.isEmpty {
            lines.append("终端刚运行的命令：\(cmd)")
        }
        let fileTitles = items.filter { $0.kind == .file }.map(\.title).prefix(5)
        if !fileTitles.isEmpty {
            lines.append("现场的文件：\(fileTitles.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    static let returnCueInstructions = """
        你是上下文助手。根据用户切换工作前的现场，生成一句「回来先做」，
        帮助用户回来时立刻想起下一步。要求：一句中文，不超过 30 字，以动词开头，
        具体（提到文件名或命令），不要解释。
        """

    static let returnBriefingInstructions = """
        你是回场助手。用户离开了一阵刚回到之前的工作，根据给出的事实生成三行简报：
        whereYouWere（你在哪：当时在做什么、具体到文件或页面）、
        whatHappened（发生了什么：等待结果、离开多久、期间捕获了什么）、
        firstStep（先做什么：动词开头的一个具体下一步）。
        每行不超过 24 个字，简体中文，只用给出的事实，不要问候和解释。
        """

    static func returnBriefingUser(_ input: ReturnBriefingInput) -> String {
        var lines = ["目标：\(input.targetName)"]
        if !input.targetNote.isEmpty { lines.append("目标说明：\(input.targetNote)") }
        if input.awayMinutes > 0 { lines.append("离开了约 \(input.awayMinutes) 分钟") }
        if !input.waitingEvidence.isEmpty { lines.append("等待结果：\(input.waitingEvidence)") }
        if !input.returnCue.isEmpty { lines.append("之前留下的返回线索：\(input.returnCue)") }
        let files = input.sceneItems.filter { $0.kind == .file }.map(\.title).prefix(5)
        if !files.isEmpty { lines.append("现场的文件：\(files.joined(separator: "、"))") }
        let links = input.sceneItems.filter { $0.kind == .link }.map(\.title).prefix(3)
        if !links.isEmpty { lines.append("现场的页面：\(links.joined(separator: "、"))") }
        if !input.capturesWhileAway.isEmpty {
            lines.append("离开期间的捕获：")
            lines.append(contentsOf: input.capturesWhileAway.prefix(5).map { "- \($0)" })
        }
        if !input.targetHistoryLine.isEmpty {
            lines.append("这件事的历史：\(input.targetHistoryLine)")
        }
        return lines.joined(separator: "\n")
    }

    static let inboxTriageInstructions = """
        你是收件箱整理助手。逐条判断每条捕获现在最合适的去向，action 必须是：
        startTarget（值得立为一件事，之后专门做）、convertToWaiting（其实在等一个外部结果）、
        saveReference（以后查阅的资料）、archive（已过期或无需处理）、keep（还看不出去向）。
        宁可 keep，不要武断归档。reason 用一句简短中文。
        输出 proposals 数组，与输入条目一一对应、顺序一致。
        """

    static func inboxTriageUser(items: [InboxTriageItem], recentTargets: [String]) -> String {
        var lines: [String] = []
        if !recentTargets.isEmpty {
            lines.append("最近在做的事：\(recentTargets.prefix(6).joined(separator: "、"))")
        }
        lines.append("收件箱条目：")
        for (index, item) in items.enumerated() {
            var meta = [item.kind.title, "\(item.ageDays) 天前"]
            if !item.tags.isEmpty {
                meta.append(item.tags.map { "#\($0)" }.joined(separator: " "))
            }
            lines.append("\(index + 1). [\(meta.joined(separator: " · "))] \(item.summary)")
            if !item.historyHint.isEmpty {
                lines.append("   历史：\(item.historyHint)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static let narrativeInstructions = """
        你是回顾记录员。把给出的注意力事实写成一段 120 字左右的简体中文叙事，
        语气平实像日志。只能复述给出的事实；不得推断原因、不得评价好坏、
        不得给建议、不用感叹号、不用「你真棒」式的话。
        """

    static func narrativeUser(_ input: NarrativeInput) -> String {
        (["周期：\(input.periodTitle)", "事实："] + input.factLines.map { "- \($0)" })
            .joined(separator: "\n")
    }

    static let memoryChatInstructions = """
        你是轻锚的记忆助手。轻锚只记录用户主动留下的工作痕迹：专注分段、等待、捕获、现场。
        依据给出的记忆事实回答用户的问题：
        - 只用事实行里的信息，不得编造；时长和数量给具体数字；
        - 事实里找不到答案就直说「记忆里没有这段记录」，并点明查的是哪个范围；
        - 与问题无关的事实不要复述；
        - 简体中文，直接回答，不要客套、不要总结式收尾。
        """

    /// 当轮的 user 消息：只装范围、事实和问题。此前的问答不再折叠进来——
    /// 云端引擎把 history 发成真正的 messages 数组（见 boundedHistory），
    /// 端侧引擎用 memoryChatUserFoldingHistory。
    static func memoryChatUser(_ input: MemoryQuestionInput) -> String {
        var lines: [String] = ["查询范围：\(input.periodTitle)", "记忆事实："]
        lines.append(contentsOf: input.factLines.map { "- \($0)" })
        lines.append("问题：\(input.question)")
        return lines.joined(separator: "\n")
    }

    /// 端侧模型（上下文窗口小、没有多轮接口的用法）用的折叠版：
    /// 把裁剪后的 history 以「问：/答：」行并入当轮提示词。
    static func memoryChatUserFoldingHistory(_ input: MemoryQuestionInput) -> String {
        let history = boundedHistory(input.history, perMessageLimit: 300, totalLimit: 1200)
        guard !history.isEmpty else { return memoryChatUser(input) }
        var lines: [String] = ["查询范围：\(input.periodTitle)", "记忆事实："]
        lines.append(contentsOf: input.factLines.map { "- \($0)" })
        lines.append("此前的对话：")
        lines.append(contentsOf: history.map { turn in
            switch turn.role {
            case .user: "问：\(turn.text)"
            case .assistant: "答：\(turn.text)"
            }
        })
        lines.append("问题：\(input.question)")
        return lines.joined(separator: "\n")
    }

    /// 把原始问答轮裁剪成能直接上线的多轮序列：
    /// - 单条过长截尾（保留开头：问答的信息密度前重后轻）；
    /// - 从最新往回收，总量超预算就停（旧轮先丢）；
    /// - 相邻同角色合并（中间可能剔除过出错回合）；
    /// - 以 user 开头、以 assistant 结尾——Anthropic 要求严格交替且首条是 user，
    ///   当轮问题会作为下一条 user 追加，所以结尾的孤儿提问也得剪掉。
    static func boundedHistory(
        _ turns: [MemoryChatTurn],
        perMessageLimit: Int = 1200,
        totalLimit: Int = 6000
    ) -> [MemoryChatTurn] {
        let clipped: [MemoryChatTurn] = turns.compactMap { turn in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let bounded = text.count <= perMessageLimit
                ? text
                : String(text.prefix(perMessageLimit)) + "…"
            return MemoryChatTurn(role: turn.role, text: bounded)
        }

        var kept: [MemoryChatTurn] = []
        var total = 0
        for turn in clipped.reversed() {
            total += turn.text.count
            if total > totalLimit, !kept.isEmpty { break }
            kept.insert(turn, at: 0)
        }

        var merged: [MemoryChatTurn] = []
        for turn in kept {
            if let last = merged.last, last.role == turn.role {
                merged[merged.count - 1].text = last.text + "\n" + turn.text
            } else {
                merged.append(turn)
            }
        }

        while merged.first?.role == .assistant { merged.removeFirst() }
        while merged.last?.role == .user { merged.removeLast() }
        return merged
    }

    static let memoryQueryRewriteInstructions = """
        你是检索助手。把用户的追问结合此前对话改写成一个独立、完整、可直接用于
        本地检索的中文问题：把「那件事」「它」这类指代替换成具体名称。
        只输出改写后的问题本身，一行，不要解释、不要引号。
        """

    static func memoryQueryRewriteUser(question: String, history: [MemoryChatTurn]) -> String {
        let bounded = boundedHistory(history, perMessageLimit: 200, totalLimit: 900)
        var lines = ["此前的对话："]
        lines.append(contentsOf: bounded.map { turn in
            switch turn.role {
            case .user: "问：\(turn.text)"
            case .assistant: "答：\(turn.text)"
            }
        })
        lines.append("需要改写的追问：\(question)")
        return lines.joined(separator: "\n")
    }

    /// 改写输出收口：取第一行、去引号、限长；空了就当没改写。
    static func normalizedRewrittenQuery(_ raw: String) -> String? {
        let firstLine = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = firstLine
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'「」“”"))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }

    static let recordGuideInstructions = """
        你是过程复盘助手。输入是软件对一段工作过程的自动记录：按时间排列的事实行
        （切到哪个应用、打开了哪个文件或网页、终端跑了什么命令、期间的想法捕获与等待结果）。
        把它整理成一篇给朋友看的 Markdown 复盘文档。
        结构：# 一级标题（用给出的标题）；一段背景（从事实推得出才写）；
        ## 步骤（有序列表，按时间归并同一动作的重复观察，命令放代码块，保留文件名和参数原文）；
        有失败重试就写进 ## 坑与注意；有明确结果就加 ## 结果。
        只能使用事实行里出现的内容：不得虚构步骤、补全命令或猜测原因；
        事实行看不出的环节直接跳过，不要脑补衔接。
        简体中文，输出纯 Markdown 正文，不要解释、不要代码围栏包裹全文。
        """

    static let recordSkillInstructions = """
        你是 skill 编写助手。输入是软件对一段工作过程的自动记录：按时间排列的事实行
        （应用/文件/网页切换、终端命令、捕获与等待结果）。
        从这个过程中提炼一份给 AI agent 阅读并执行的 SKILL.md。
        文件开头必须是 YAML frontmatter（用 --- 包裹）：
        name 是 kebab-case 的英文短名；description 用一句话说清这个 skill 做什么、什么时候该用
        （agent 靠它决定是否加载这个 skill）。
        正文结构：# 技能名；一段简述；## 适用场景（什么触发条件下用）；
        ## 执行步骤（有序列表，每步是给 agent 的明确指令，动词开头，命令放代码块，
        写明在哪个目录、对哪个文件）；## 验证（执行完如何确认成功）。
        步骤只能来自事实行：命令与路径必须原样照抄，不得虚构；重复的试错归并成一步，
        从事实看不准的步骤明确标注「需确认」。
        输出纯 SKILL.md 内容（从 --- 开始），不要解释、不要代码围栏包裹全文。
        """

    static func recordComposeInstructions(for style: RecordingStyle) -> String {
        switch style {
        case .guide: recordGuideInstructions
        case .skill: recordSkillInstructions
        }
    }

    static func recordComposeUser(_ input: RecordComposeInput) -> String {
        var lines = ["标题：\(input.title.isEmpty ? "（未起标题，请从过程提炼）" : input.title)"]
        lines.append("过程事实（按时间顺序）：")
        lines.append(contentsOf: input.factLines.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }

    /// ADHD 友好输出塑形（来自 github.com/ayghri/i-have-adhd 技能的核心规则）。
    /// 附加在文字生成类指令之后；与任务本身的格式约定冲突时任务优先，
    /// 但「具体、短句、无铺垫」始终保持。
    static let adhdOutputStyle = """
        读者有 ADHD，输出要让人能直接行动，按以下规则塑形
        （若与上面任务本身的格式要求冲突，以任务要求为准，但始终保持具体、短句、无铺垫）：
        - 能行动的内容放在最前面，动词开头，具体到文件名、命令或页面；
        - 多于一步就用编号列表，每步只做一件事，最多 5 项；
        - 时间和数量给具体数字，不用「稍微」「一会儿」「一些」这类模糊量词；
        - 不写铺垫、不写客套、不写「加油」式打气话，说完即止；
        - 说到已完成的事时讲清现在能做什么，不埋进总结里。
        """

    /// 按偏好把 ADHD 塑形规则拼进指令。
    static func styled(_ instructions: String, adhdFriendly: Bool) -> String {
        adhdFriendly ? instructions + "\n\n" + adhdOutputStyle : instructions
    }
}

// MARK: - 启发式降级引擎
//
// 无 AI 可用时的确定性降级：只做事实拼装（简报/提示/叙事/复述），不做猜测——
// 相关性与收件箱去向这类判断，无法判断就如实说无法判断，绝不用先验冒充。

struct HeuristicIntelligenceEngine: IntelligenceEngineProtocol {
    let name = "启发式（离线）"
    let isAvailable = true

    func filterSceneItems(
        items: [SceneItem],
        targetName: String,
        targetNote: String
    ) async -> [SceneRelevanceResult] {
        // 不猜相关性：关键词重叠和应用类别先验对很多目标会系统性误判（回邮件时
        // Mail 不是干扰）。返回空＝无法判断，调用方全部保留，宁可多存不漏存。
        []
    }

    func generateReturnCue(
        items: [SceneItem],
        targetName: String,
        lastEditedFile: String?,
        lastTerminalCommand: String?
    ) async -> String {
        var parts: [String] = []
        if let file = lastEditedFile, !file.isEmpty {
            parts.append("继续改 \((file as NSString).lastPathComponent)")
        }
        if let cmd = lastTerminalCommand, !cmd.isEmpty {
            parts.append("跑完 \(cmd)")
        }
        if parts.isEmpty, let first = items.first(where: { $0.kind == .file }) {
            parts.append("继续 \(first.title)")
        }
        return parts.isEmpty ? "回到 \(targetName)" : parts.joined(separator: "，然后")
    }

    func generateReturnBriefing(_ input: ReturnBriefingInput) async -> ReturnBriefing? {
        let whereYouWere: String
        if let file = input.sceneItems.first(where: { $0.kind == .file })?.title, !file.isEmpty {
            whereYouWere = "在「\(input.targetName)」里改 \(file)"
        } else if let link = input.sceneItems.first(where: { $0.kind == .link })?.title, !link.isEmpty {
            whereYouWere = "在「\(input.targetName)」里看 \(link)"
        } else {
            whereYouWere = "在做「\(input.targetName)」"
        }

        var happened: [String] = []
        if !input.waitingEvidence.isEmpty {
            happened.append(input.waitingEvidence)
        }
        if input.awayMinutes > 0 {
            happened.append("离开了约 \(input.awayMinutes) 分钟")
        }
        if !input.capturesWhileAway.isEmpty {
            happened.append("其间捕获了 \(input.capturesWhileAway.count) 条想法")
        }

        let firstStep = input.returnCue.isEmpty
            ? "接着推进「\(input.targetName)」"
            : input.returnCue

        return ReturnBriefing(
            whereYouWere: whereYouWere,
            whatHappened: happened.isEmpty ? "这段时间没有新的结果" : happened.joined(separator: "；"),
            firstStep: firstStep
        )
    }

    func triageInbox(
        items: [InboxTriageItem],
        recentTargets: [String]
    ) async -> [InboxTriageProposal] {
        // 不猜去向：类别先验（链接＝资料）和久放先验（14 天＝归档）都是猜测，已取消；
        // 理解意图留给模型。有历史去向证据时如实转述，行动一律「先留着」，由用户定夺。
        items.map { item in
            InboxTriageProposal(
                captureID: item.captureID,
                action: .keep,
                reason: item.historyHint.isEmpty ? "还看不出去向，先留着" : item.historyHint
            )
        }
    }

    func generateNarrative(_ input: NarrativeInput) async -> String? {
        guard !input.factLines.isEmpty else { return nil }
        return "\(input.periodTitle)：" + input.factLines.joined(separator: "；") + "。"
    }

    func answerMemoryQuestion(_ input: MemoryQuestionInput) async -> String {
        // 确定性复述：不理解问题，只把检索到的事实按序摆出来。
        // 这是透明的规则输出，UI 会如实署名「启发式（离线）」。永不失败。
        guard !input.factLines.isEmpty else {
            return "记忆里没有\(input.periodTitle)的记录。"
        }
        var lines = ["按\(input.periodTitle)的记录："]
        lines.append(contentsOf: input.factLines.prefix(9).map { "· \($0)" })
        let rest = input.factLines.count - 9
        if rest > 0 { lines.append("（其余 \(rest) 条略）") }
        return lines.joined(separator: "\n")
    }

    func composeRecordMarkdown(_ input: RecordComposeInput) async -> String {
        // 确定性拼装：不提炼、不归并，把过程事实按序摆进对应格式的壳。
        // 输出署名「启发式（离线）」，用户看得出这是没过模型的结果。永不失败。
        let title = input.title.isEmpty ? "未命名记录" : input.title
        let facts = input.factLines.map { "- \($0)" }.joined(separator: "\n")
        switch input.style {
        case .guide:
            return "# \(title)\n\n## 过程\n\n\(facts)"
        case .skill:
            let slug = RecordingSession.slug(from: input.title)
            return """
                ---
                name: \(slug.isEmpty ? "untitled-skill" : slug)
                description: \(title)
                ---

                # \(title)

                ## 过程事实（按时间顺序）

                \(facts)
                """
        }
    }
}

// MARK: - FoundationModels 端侧引擎（macOS 26+）

#if canImport(FoundationModels) && !LIGHTANCHOR_DISABLE_FOUNDATIONMODELS

@available(macOS 26.0, *)
@Generable
struct SceneRelevanceGeneration {
    @Guide(description: "与输入条目一一对应的相关性判断，数量和顺序必须一致")
    var results: [Entry]

    @Generable
    struct Entry {
        @Guide(description: "该条目是否与当前目标相关")
        var isRelevant: Bool
        @Guide(description: "一句简短中文理由")
        var reason: String
    }
}

@available(macOS 26.0, *)
@Generable
struct ReturnBriefingGeneration {
    @Guide(description: "你在哪：当时在做什么，具体到文件或页面，不超过 24 字")
    var whereYouWere: String
    @Guide(description: "发生了什么：等待结果/离开多久/期间捕获，不超过 24 字")
    var whatHappened: String
    @Guide(description: "先做什么：动词开头的一个具体下一步，不超过 24 字")
    var firstStep: String
}

@available(macOS 26.0, *)
@Generable
struct InboxTriageGeneration {
    @Guide(description: "与输入条目一一对应的处置提议，数量和顺序必须一致")
    var proposals: [Entry]

    @Generable
    struct Entry {
        @Guide(description: "去向", .anyOf([
            "startTarget", "convertToWaiting", "saveReference", "archive", "keep"
        ]))
        var action: String
        @Guide(description: "一句简短中文理由")
        var reason: String
    }
}

@available(macOS 26.0, *)
struct FoundationModelsIntelligenceEngine: IntelligenceEngineProtocol {
    let name = "端侧（Apple 智能）"

    /// ADHD 友好输出：文字生成类指令追加塑形规则。
    var adhdFriendlyOutput: Bool = true

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    private let fallback = HeuristicIntelligenceEngine()

    func filterSceneItems(
        items: [SceneItem],
        targetName: String,
        targetNote: String
    ) async -> [SceneRelevanceResult] {
        // 不可用/失败/数量对不上：返回空＝无法判断，调用方全部保留。不冒充判断。
        guard isAvailable, !items.isEmpty else { return [] }
        do {
            let session = LanguageModelSession(instructions: IntelligencePrompts.sceneFilterInstructions)
            let response = try await session.respond(
                to: IntelligencePrompts.sceneFilterUser(items: items, targetName: targetName, targetNote: targetNote),
                generating: SceneRelevanceGeneration.self
            )
            let entries = response.content.results
            guard entries.count == items.count else { return [] }
            return zip(items, entries).map { item, entry in
                SceneRelevanceResult(itemID: item.id, isRelevant: entry.isRelevant, reason: entry.reason)
            }
        } catch {
            return []
        }
    }

    func generateReturnCue(
        items: [SceneItem],
        targetName: String,
        lastEditedFile: String?,
        lastTerminalCommand: String?
    ) async -> String {
        guard isAvailable else {
            return await fallback.generateReturnCue(
                items: items, targetName: targetName,
                lastEditedFile: lastEditedFile, lastTerminalCommand: lastTerminalCommand
            )
        }
        do {
            let session = LanguageModelSession(instructions: IntelligencePrompts.styled(
                IntelligencePrompts.returnCueInstructions, adhdFriendly: adhdFriendlyOutput
            ))
            let response = try await session.respond(
                to: IntelligencePrompts.returnCueUser(
                    items: items, targetName: targetName,
                    lastEditedFile: lastEditedFile, lastTerminalCommand: lastTerminalCommand
                )
            )
            let cue = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return cue.isEmpty
                ? await fallback.generateReturnCue(
                    items: items, targetName: targetName,
                    lastEditedFile: lastEditedFile, lastTerminalCommand: lastTerminalCommand
                )
                : cue
        } catch {
            return await fallback.generateReturnCue(
                items: items, targetName: targetName,
                lastEditedFile: lastEditedFile, lastTerminalCommand: lastTerminalCommand
            )
        }
    }

    func generateReturnBriefing(_ input: ReturnBriefingInput) async -> ReturnBriefing? {
        guard isAvailable else {
            return await fallback.generateReturnBriefing(input)
        }
        do {
            let session = LanguageModelSession(instructions: IntelligencePrompts.styled(
                IntelligencePrompts.returnBriefingInstructions, adhdFriendly: adhdFriendlyOutput
            ))
            let response = try await session.respond(
                to: IntelligencePrompts.returnBriefingUser(input),
                generating: ReturnBriefingGeneration.self
            )
            let content = response.content
            let briefing = ReturnBriefing(
                whereYouWere: content.whereYouWere.trimmingCharacters(in: .whitespacesAndNewlines),
                whatHappened: content.whatHappened.trimmingCharacters(in: .whitespacesAndNewlines),
                firstStep: content.firstStep.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !briefing.firstStep.isEmpty else {
                return await fallback.generateReturnBriefing(input)
            }
            return briefing
        } catch {
            return await fallback.generateReturnBriefing(input)
        }
    }

    func triageInbox(
        items: [InboxTriageItem],
        recentTargets: [String]
    ) async -> [InboxTriageProposal] {
        guard isAvailable, !items.isEmpty else {
            return await fallback.triageInbox(items: items, recentTargets: recentTargets)
        }
        do {
            let session = LanguageModelSession(instructions: IntelligencePrompts.styled(
                IntelligencePrompts.inboxTriageInstructions, adhdFriendly: adhdFriendlyOutput
            ))
            let response = try await session.respond(
                to: IntelligencePrompts.inboxTriageUser(items: items, recentTargets: recentTargets),
                generating: InboxTriageGeneration.self
            )
            let entries = response.content.proposals
            guard entries.count == items.count else {
                return await fallback.triageInbox(items: items, recentTargets: recentTargets)
            }
            return zip(items, entries).map { item, entry in
                InboxTriageProposal(
                    captureID: item.captureID,
                    action: InboxTriageAction(rawValue: entry.action) ?? .keep,
                    reason: entry.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } catch {
            return await fallback.triageInbox(items: items, recentTargets: recentTargets)
        }
    }

    func generateNarrative(_ input: NarrativeInput) async -> String? {
        guard isAvailable else {
            return await fallback.generateNarrative(input)
        }
        do {
            let session = LanguageModelSession(instructions: IntelligencePrompts.styled(
                IntelligencePrompts.narrativeInstructions, adhdFriendly: adhdFriendlyOutput
            ))
            let response = try await session.respond(to: IntelligencePrompts.narrativeUser(input))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? await fallback.generateNarrative(input) : text
        } catch {
            return await fallback.generateNarrative(input)
        }
    }

    func answerMemoryQuestion(_ input: MemoryQuestionInput) async throws -> String {
        // 刻意不静默兜底：不可用或失败直接抛错，由调用方原样亮给用户。
        guard isAvailable else {
            throw MemoryAnswerError.engineUnavailable(tr("the_on_device_model_is_unavailable"))
        }
        let session = LanguageModelSession(instructions: IntelligencePrompts.styled(
            IntelligencePrompts.memoryChatInstructions, adhdFriendly: adhdFriendlyOutput
        ))
        let response = try await session.respond(
            to: IntelligencePrompts.memoryChatUserFoldingHistory(input)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MemoryAnswerError.emptyAnswer }
        return text
    }

    func streamMemoryAnswer(_ input: MemoryQuestionInput) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard isAvailable else {
                        throw MemoryAnswerError.engineUnavailable(tr("the_on_device_model_is_unavailable"))
                    }
                    let session = LanguageModelSession(instructions: IntelligencePrompts.styled(
                        IntelligencePrompts.memoryChatInstructions, adhdFriendly: adhdFriendlyOutput
                    ))
                    // 端侧的流元素本来就是累积快照，与协议约定的累积语义一致，直接转发。
                    var latest = ""
                    for try await partial in session.streamResponse(
                        to: IntelligencePrompts.memoryChatUserFoldingHistory(input)
                    ) {
                        latest = partial.content
                        continuation.yield(latest)
                    }
                    guard !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw MemoryAnswerError.emptyAnswer
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func rewriteMemoryQuery(question: String, history: [MemoryChatTurn]) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(
            instructions: IntelligencePrompts.memoryQueryRewriteInstructions
        )
        guard let response = try? await session.respond(
            to: IntelligencePrompts.memoryQueryRewriteUser(question: question, history: history)
        ) else { return nil }
        return IntelligencePrompts.normalizedRewrittenQuery(response.content)
    }

    func composeRecordMarkdown(_ input: RecordComposeInput) async throws -> String {
        // 用户主动点的整理：不可用或失败直接抛错，不冒名降级。
        guard isAvailable else {
            throw MemoryAnswerError.engineUnavailable(tr("the_on_device_model_is_unavailable"))
        }
        let session = LanguageModelSession(
            instructions: IntelligencePrompts.recordComposeInstructions(for: input.style)
        )
        let response = try await session.respond(
            to: IntelligencePrompts.recordComposeUser(input)
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MemoryAnswerError.emptyAnswer }
        return text
    }
}

#endif

// MARK: - 云端连接配置

/// 配置是否够发一次请求。API Key 不在其中：空 Key 是合法配置（免鉴权网关、
/// 本地服务），钥匙对不对由服务端说，不由这里猜。
enum CloudConfigurationStatus: Equatable, Sendable {
    case ready
    case invalidEndpoint
    case missingModel
}

struct CloudConnectionConfiguration: Equatable, Sendable {
    let apiKey: String
    let normalizedChatEndpoint: String
    let normalizedModelsEndpoint: String
    let model: String

    init(
        apiKey: String,
        chatEndpoint: String,
        modelsEndpoint: String,
        model: String
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizedChatEndpoint = Self.normalize(chatEndpoint)
        self.normalizedModelsEndpoint = Self.normalize(modelsEndpoint)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalize(_ endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 各协议真正的请求路径。
    static func requestPath(for apiProtocol: CloudAPIProtocol) -> String {
        switch apiProtocol {
        case .openAIChatCompletions: "/chat/completions"
        case .openAIResponses: "/responses"
        case .anthropicMessages: "/messages"
        }
    }

    static let knownRequestPaths = ["/chat/completions", "/completions", "/responses", "/messages"]

    /// 把用户填的地址补成真正可 POST 的请求端点。
    ///
    /// 各家服务的文档给的几乎都是「基地址」（`https://…/v1`），照原样 POST
    /// 只会拿回一个 404——这不是用户填错，是我们该补的一段路径。所以：
    /// 已经是请求路径的原样不动；只有域名的按 OpenAI 兼容惯例补 `/v1` 加请求
    /// 路径；停在版本段（`/v1`、`/v1beta`）的补上请求路径。其余路径可能就是
    /// 这家服务真正的路由，一律不猜，原样发出去。
    static func completedRequestEndpoint(
        _ endpoint: String,
        for apiProtocol: CloudAPIProtocol
    ) -> String {
        let normalized = normalize(endpoint)
        guard let url = url(from: normalized),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return normalized
        }
        let path = components.path
        guard !knownRequestPaths.contains(where: { path.hasSuffix($0) }) else { return normalized }

        let requestPath = requestPath(for: apiProtocol)
        let lastSegment = path.split(separator: "/").last.map(String.init) ?? ""
        if path.isEmpty || path == "/" {
            components.path = "/v1" + requestPath
        } else if isVersionSegment(lastSegment) {
            components.path = path + requestPath
        } else {
            // 版本段之外的路径可能就是这家服务真正的路由（Ollama 的 /api/chat
            // 就是一个），不替用户改。
            return normalized
        }
        return components.url?.absoluteString ?? normalized
    }

    /// `v1`、`v1beta`、`v2` 这类版本段——地址停在这里就是个基地址。
    private static func isVersionSegment(_ segment: String) -> Bool {
        guard segment.hasPrefix("v"), let second = segment.dropFirst().first else { return false }
        return second.isNumber
    }

    /// 从请求端点推导模型列表端点：预设服务之外（自定义/改过地址）不再让用户
    /// 单独填一格，而是把已知的请求路径换成 /models。
    static func deriveModelsEndpoint(fromChatEndpoint chatEndpoint: String) -> String? {
        guard let url = url(from: chatEndpoint) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = url.path
        if let suffix = knownRequestPaths.first(where: { path.hasSuffix($0) }) {
            components?.path = String(path.dropLast(suffix.count)) + "/models"
        } else {
            // 未知路径：把最后一段换成 models（…/api/chat → …/api/models）。
            var segments = path.split(separator: "/").map(String.init)
            if !segments.isEmpty { segments.removeLast() }
            components?.path = "/" + (segments + ["models"]).joined(separator: "/")
        }
        return components?.url?.absoluteString
    }

    static func url(from endpoint: String) -> URL? {
        let normalizedEndpoint = normalize(endpoint)
        guard let components = URLComponents(string: normalizedEndpoint),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return components.url
    }

    var modelsURL: URL? {
        Self.url(from: normalizedModelsEndpoint)
    }

    var chatURL: URL? {
        Self.url(from: normalizedChatEndpoint)
    }

    var status: CloudConfigurationStatus {
        guard chatURL != nil else { return .invalidEndpoint }
        guard !model.isEmpty else { return .missingModel }
        return .ready
    }
}

// MARK: - 出网规则

/// 所有云端请求（对话、流式、模型列表、抓链接标题）共用的一套出网规则：
/// 1. 不跟着重定向换主机或降级协议——带着 Key 的请求被 302 到别处，Key 就送人了；
/// 2. Key 只走 https；明文 http 只许发给本机（Ollama / LM Studio 那类本地服务）。
enum CloudNetworkPolicy {
    enum Error: LocalizedError, Equatable {
        /// 想把 API Key 发到非本机的 http:// 端点。
        case apiKeyOverInsecureTransport(host: String)

        var errorDescription: String? {
            switch self {
            case .apiKeyOverInsecureTransport(let host):
                String(format: tr("cloud_endpoint_requires_https_for_api_key"), host)
            }
        }
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// 全部云端请求共用的会话：临时配置（不落缓存、不留 cookie），
    /// 重定向由 `CloudRedirectGuard` 把关。
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: CloudRedirectGuard(), delegateQueue: nil)
    }()

    static func isLoopback(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return loopbackHosts.contains(host)
    }

    /// 明文 http 且目标不是本机：Key 会裸着走网络。
    static func isInsecureRemote(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return !isLoopback(host: url.host)
    }

    /// 同上，接受用户填的端点文本（解析不出 URL 时算不上「不安全」，那是另一种错）。
    static func isInsecureRemote(endpoint: String) -> Bool {
        guard let url = CloudConnectionConfiguration.url(from: endpoint) else { return false }
        return isInsecureRemote(url: url)
    }

    /// 要带 Key 的请求，先过这一关。空 Key 不受限：本地服务、免鉴权网关照旧。
    static func validateAPIKeyTransport(url: URL, apiKey: String) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isInsecureRemote(url: url) {
            throw Error.apiKeyOverInsecureTransport(host: url.host ?? url.absoluteString)
        }
    }

    /// 重定向是否还留在原地：主机、端口不变，协议不变或只许 http → https 升级。
    static func allowsRedirect(from original: URL, to next: URL) -> Bool {
        guard let originalScheme = original.scheme?.lowercased(),
              let nextScheme = next.scheme?.lowercased(),
              let originalHost = original.host?.lowercased(),
              let nextHost = next.host?.lowercased(),
              originalHost == nextHost else {
            return false
        }
        if originalScheme == nextScheme {
            return effectivePort(of: original) == effectivePort(of: next)
        }
        // 升级到 https：默认端口自然从 80 变 443，只要求显式端口不变。
        guard originalScheme == "http", nextScheme == "https" else { return false }
        return original.port == next.port
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// 拒绝换主机、换端口、降协议的重定向：`completionHandler(nil)` 让会话把那个
/// 3xx 原样交回调用方，调用方按非 2xx 报错，Key 一步都不多走。
final class CloudRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let next = request.url,
              CloudNetworkPolicy.allowsRedirect(from: original, to: next) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct CloudModelCatalog: Sendable {
    enum Error: LocalizedError, Equatable {
        case missingModelsEndpoint
        case httpError(Int, String? = nil)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingModelsEndpoint: tr("this_service_has_no_model_list")
            case .httpError(let code, let message):
                if let message {
                    "模型列表请求失败（HTTP \(code)）：\(message)"
                } else {
                    "模型列表请求失败（HTTP \(code)）。"
                }
            case .malformedResponse: tr("couldn_t_parse_the_service_s")
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = CloudNetworkPolicy.session) {
        self.session = session
    }

    func fetchModels(
        apiKey: String,
        endpoint: String,
        apiProtocol: CloudAPIProtocol = .openAIChatCompletions
    ) async throws -> [String] {
        // Key 为空也照发：不带认证头的请求由服务端裁决（可能就是允许的）。
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = CloudConnectionConfiguration.url(from: endpoint) else {
            throw Error.missingModelsEndpoint
        }
        try CloudNetworkPolicy.validateAPIKeyTransport(url: url, apiKey: trimmedAPIKey)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        CloudIntelligenceEngine.applyAuthentication(
            to: &request,
            apiKey: trimmedAPIKey,
            apiProtocol: apiProtocol
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.httpError(
                http.statusCode,
                CloudIntelligenceEngine.serverErrorMessage(from: data)
            )
        }
        return try Self.decodeModelIDs(from: data)
    }

    static func decodeModelIDs(from data: Data) throws -> [String] {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = payload["data"] as? [[String: Any]] else {
            throw Error.malformedResponse
        }

        let ids = rows.compactMap { row in
            (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let uniqueIDs = Set(ids).filter { !$0.isEmpty }
        guard !uniqueIDs.isEmpty else { throw Error.malformedResponse }
        return uniqueIDs.sorted()
    }
}

// MARK: - 云端引擎（用户自带 Key）

struct CloudIntelligenceEngine: IntelligenceEngineProtocol {
    let name = "云端增强"

    let apiKey: String
    let endpoint: String
    let model: String
    let apiProtocol: CloudAPIProtocol
    /// ADHD 友好输出：文字生成类指令追加塑形规则。
    let adhdFriendlyOutput: Bool
    private let fallback = HeuristicIntelligenceEngine()
    private let session: URLSession

    init(
        apiKey: String,
        endpoint: String,
        model: String,
        apiProtocol: CloudAPIProtocol = .openAIChatCompletions,
        adhdFriendlyOutput: Bool = true,
        session: URLSession = CloudNetworkPolicy.session
    ) {
        self.apiKey = apiKey
        // 基地址（…/v1）也照发：请求路径在这里补齐，见 completedRequestEndpoint。
        self.endpoint = CloudConnectionConfiguration.completedRequestEndpoint(
            endpoint,
            for: apiProtocol
        )
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiProtocol = apiProtocol
        self.adhdFriendlyOutput = adhdFriendlyOutput
        self.session = session
    }

    var isAvailable: Bool {
        CloudConnectionConfiguration(
            apiKey: apiKey,
            chatEndpoint: endpoint,
            modelsEndpoint: "",
            model: model
        ).status == .ready
    }

    /// 测试连接：发一条最小对话，成功则返回往返耗时（秒）。
    func testConnection() async throws -> TimeInterval {
        let started = Date()
        _ = try await chat(
            system: "你是连接测试。",
            user: "收到请只回复：pong",
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        return Date().timeIntervalSince(started)
    }

    func filterSceneItems(
        items: [SceneItem],
        targetName: String,
        targetNote: String
    ) async -> [SceneRelevanceResult] {
        // 不可用/失败/数量对不上：返回空＝无法判断，调用方全部保留。不冒充判断。
        guard isAvailable, !items.isEmpty else { return [] }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "results": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "isRelevant": ["type": "boolean"],
                            "reason": ["type": "string"]
                        ],
                        "required": ["isRelevant", "reason"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["results"],
            "additionalProperties": false
        ]
        do {
            let content = try await chat(
                system: IntelligencePrompts.sceneFilterInstructions,
                user: IntelligencePrompts.sceneFilterUser(items: items, targetName: targetName, targetNote: targetNote),
                jsonSchemaName: "scene_relevance",
                jsonSchema: schema
            )
            guard let data = content.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = parsed["results"] as? [[String: Any]],
                  results.count == items.count
            else { return [] }
            return zip(items, results).map { item, result in
                SceneRelevanceResult(
                    itemID: item.id,
                    isRelevant: result["isRelevant"] as? Bool ?? true,
                    reason: result["reason"] as? String ?? ""
                )
            }
        } catch {
            return []
        }
    }

    func generateReturnCue(
        items: [SceneItem],
        targetName: String,
        lastEditedFile: String?,
        lastTerminalCommand: String?
    ) async -> String {
        guard isAvailable else {
            return await fallback.generateReturnCue(
                items: items, targetName: targetName,
                lastEditedFile: lastEditedFile, lastTerminalCommand: lastTerminalCommand
            )
        }
        do {
            let content = try await chat(
                system: IntelligencePrompts.styled(
                    IntelligencePrompts.returnCueInstructions, adhdFriendly: adhdFriendlyOutput
                ),
                user: IntelligencePrompts.returnCueUser(
                    items: items, targetName: targetName,
                    lastEditedFile: lastEditedFile, lastTerminalCommand: lastTerminalCommand
                ),
                jsonSchemaName: nil,
                jsonSchema: nil
            )
            let cue = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return cue.isEmpty
                ? await fallback.generateReturnCue(
                    items: items, targetName: targetName,
                    lastEditedFile: lastEditedFile, lastTerminalCommand: lastTerminalCommand
                )
                : cue
        } catch {
            return await fallback.generateReturnCue(
                items: items, targetName: targetName,
                lastEditedFile: lastEditedFile, lastTerminalCommand: lastTerminalCommand
            )
        }
    }

    func generateReturnBriefing(_ input: ReturnBriefingInput) async -> ReturnBriefing? {
        guard isAvailable else {
            return await fallback.generateReturnBriefing(input)
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "whereYouWere": ["type": "string"],
                "whatHappened": ["type": "string"],
                "firstStep": ["type": "string"]
            ],
            "required": ["whereYouWere", "whatHappened", "firstStep"],
            "additionalProperties": false
        ]
        do {
            let content = try await chat(
                system: IntelligencePrompts.styled(
                    IntelligencePrompts.returnBriefingInstructions, adhdFriendly: adhdFriendlyOutput
                ),
                user: IntelligencePrompts.returnBriefingUser(input),
                jsonSchemaName: "return_briefing",
                jsonSchema: schema
            )
            guard let data = content.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let firstStep = (parsed["firstStep"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !firstStep.isEmpty
            else {
                return await fallback.generateReturnBriefing(input)
            }
            return ReturnBriefing(
                whereYouWere: (parsed["whereYouWere"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                whatHappened: (parsed["whatHappened"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                firstStep: firstStep
            )
        } catch {
            return await fallback.generateReturnBriefing(input)
        }
    }

    func triageInbox(
        items: [InboxTriageItem],
        recentTargets: [String]
    ) async -> [InboxTriageProposal] {
        guard isAvailable, !items.isEmpty else {
            return await fallback.triageInbox(items: items, recentTargets: recentTargets)
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "proposals": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "action": [
                                "type": "string",
                                "enum": InboxTriageAction.allCases.map(\.rawValue)
                            ],
                            "reason": ["type": "string"]
                        ],
                        "required": ["action", "reason"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["proposals"],
            "additionalProperties": false
        ]
        do {
            let content = try await chat(
                system: IntelligencePrompts.styled(
                    IntelligencePrompts.inboxTriageInstructions, adhdFriendly: adhdFriendlyOutput
                ),
                user: IntelligencePrompts.inboxTriageUser(items: items, recentTargets: recentTargets),
                jsonSchemaName: "inbox_triage",
                jsonSchema: schema
            )
            guard let data = content.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proposals = parsed["proposals"] as? [[String: Any]],
                  proposals.count == items.count
            else {
                return await fallback.triageInbox(items: items, recentTargets: recentTargets)
            }
            return zip(items, proposals).map { item, proposal in
                InboxTriageProposal(
                    captureID: item.captureID,
                    action: (proposal["action"] as? String).flatMap(InboxTriageAction.init(rawValue:)) ?? .keep,
                    reason: (proposal["reason"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } catch {
            return await fallback.triageInbox(items: items, recentTargets: recentTargets)
        }
    }

    func generateNarrative(_ input: NarrativeInput) async -> String? {
        guard isAvailable else {
            return await fallback.generateNarrative(input)
        }
        do {
            let content = try await chat(
                system: IntelligencePrompts.styled(
                    IntelligencePrompts.narrativeInstructions, adhdFriendly: adhdFriendlyOutput
                ),
                user: IntelligencePrompts.narrativeUser(input),
                jsonSchemaName: nil,
                jsonSchema: nil
            )
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? await fallback.generateNarrative(input) : text
        } catch {
            return await fallback.generateNarrative(input)
        }
    }

    func answerMemoryQuestion(_ input: MemoryQuestionInput) async throws -> String {
        // 刻意不静默兜底：配置不全或请求失败直接抛错（带服务端原文），
        // 由调用方原样亮给用户（用户定：有错误就显示错误）。
        guard isAvailable else {
            throw MemoryAnswerError.engineUnavailable(tr("the_cloud_engine_is_not_configured"))
        }
        let content = try await chat(
            system: IntelligencePrompts.styled(
                IntelligencePrompts.memoryChatInstructions, adhdFriendly: adhdFriendlyOutput
            ),
            user: IntelligencePrompts.memoryChatUser(input),
            history: IntelligencePrompts.boundedHistory(input.history),
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rewriteMemoryQuery(question: String, history: [MemoryChatTurn]) async -> String? {
        // 锦上添花语义：任何失败都返回 nil，由调用方用原句检索。
        guard isAvailable else { return nil }
        guard let content = try? await chat(
            system: IntelligencePrompts.memoryQueryRewriteInstructions,
            user: IntelligencePrompts.memoryQueryRewriteUser(question: question, history: history),
            jsonSchemaName: nil,
            jsonSchema: nil
        ) else { return nil }
        return IntelligencePrompts.normalizedRewrittenQuery(content)
    }

    func composeRecordMarkdown(_ input: RecordComposeInput) async throws -> String {
        // 用户主动点的整理：配置不全或请求失败直接抛错（带服务端原文）。
        guard isAvailable else {
            throw MemoryAnswerError.engineUnavailable(tr("the_cloud_engine_is_not_configured"))
        }
        let content = try await chat(
            system: IntelligencePrompts.recordComposeInstructions(for: input.style),
            user: IntelligencePrompts.recordComposeUser(input),
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MemoryAnswerError.emptyAnswer }
        return text
    }

    // MARK: - HTTP

    enum CloudEngineError: LocalizedError {
        case badEndpoint
        case httpError(Int, String? = nil, requestedURL: String? = nil)
        case malformedResponse
        /// 流式回合中途由服务端事件报告的失败（HTTP 已是 2xx，错误在流里）。
        case streamFailed(String)

        var errorDescription: String? {
            switch self {
            case .badEndpoint: tr("invalid_cloud_endpoint")
            case .streamFailed(let message): "云端流式返回错误：\(message)"
            case .httpError(let code, let message, let requestedURL):
                if let message {
                    "云端接口返回错误（\(code)）：\(message)"
                } else if code == 404 {
                    // 404 是路径或模型不对——光报数字没法排查，
                    // 把真正请求过的地址亮出来，用户一眼能对照。
                    "云端接口返回错误（404）。"
                        + (requestedURL.map { "请求地址：\($0)。" } ?? "")
                        + "请检查该地址是否是这家服务的请求端点，以及模型 ID 是否受支持。"
                } else {
                    "云端接口返回错误（\(code)）。"
                }
            case .malformedResponse: tr("the_cloud_service_returned_something_unparseable")
            }
        }
    }

    /// 从失败响应体里挖出服务端的报错文本（OpenAI/Anthropic 兼容格式），
    /// 让「测试连接」失败时能看到原因而不是一个裸状态码。
    static func serverErrorMessage(from data: Data) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let raw: String? = if let error = parsed["error"] as? [String: Any] {
            error["message"] as? String
        } else if let message = parsed["message"] as? String {
            message
        } else {
            parsed["error"] as? String
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(300))
    }

    static let anthropicVersion = "2023-06-01"

    static func applyAuthentication(
        to request: inout URLRequest,
        apiKey: String,
        apiProtocol: CloudAPIProtocol
    ) {
        // Key 为空：不发认证头（本地服务、免鉴权网关都属于这种）。
        guard !apiKey.isEmpty else {
            if apiProtocol == .anthropicMessages {
                request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            }
            return
        }
        switch apiProtocol {
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openAIChatCompletions, .openAIResponses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    static func makeRequest(
        apiKey: String,
        endpoint: String,
        model: String,
        apiProtocol: CloudAPIProtocol,
        system: String,
        user: String,
        history: [MemoryChatTurn] = [],
        jsonSchemaName: String?,
        jsonSchema: [String: Any]?,
        streaming: Bool = false
    ) throws -> URLRequest {
        guard let url = CloudConnectionConfiguration.url(from: endpoint) else {
            throw CloudEngineError.badEndpoint
        }
        // Key 只走 https（本机 http 例外）：在拼请求这一步就拦住，一个字节都不发。
        try CloudNetworkPolicy.validateAPIKeyTransport(url: url, apiKey: apiKey)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // timeoutInterval 是「两段数据之间」的空闲上限：流式回合推理模型出首字
        // 可能远超 30 秒，放宽到 180——反正用户随时能停；单发请求维持 30 秒。
        request.timeoutInterval = streaming ? 180 : 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthentication(to: &request, apiKey: apiKey, apiProtocol: apiProtocol)

        // 此前的问答按角色原样入列（调用方已用 boundedHistory 裁剪成合法交替序列）。
        let historyMessages: [[String: Any]] = history.map {
            ["role": $0.role.rawValue, "content": $0.text]
        }

        let body: [String: Any]
        switch apiProtocol {
        case .openAIChatCompletions:
            var chatBody: [String: Any] = [
                "model": model,
                "messages": [["role": "system", "content": system]]
                    + historyMessages
                    + [["role": "user", "content": user]],
                "temperature": 0.2
            ]
            if let jsonSchemaName, let jsonSchema {
                chatBody["response_format"] = [
                    "type": "json_schema",
                    "json_schema": [
                        "name": jsonSchemaName,
                        "strict": true,
                        "schema": jsonSchema
                    ]
                ]
            }
            if streaming { chatBody["stream"] = true }
            body = chatBody

        case .openAIResponses:
            var responsesBody: [String: Any] = [
                "model": model,
                "instructions": system,
                // 没有历史时维持纯字符串（老形态）；有历史才升级成消息数组。
                "input": historyMessages.isEmpty
                    ? user
                    : historyMessages + [["role": "user", "content": user]],
                "max_output_tokens": 2048
            ]
            if let jsonSchemaName, let jsonSchema {
                responsesBody["text"] = [
                    "format": [
                        "type": "json_schema",
                        "name": jsonSchemaName,
                        "strict": true,
                        "schema": jsonSchema
                    ]
                ]
            }
            if streaming { responsesBody["stream"] = true }
            body = responsesBody

        case .anthropicMessages:
            var anthropicBody: [String: Any] = [
                "model": model,
                "system": system,
                "messages": historyMessages + [["role": "user", "content": user]],
                "max_tokens": 2048,
                "temperature": 0.2
            ]
            if let jsonSchema {
                anthropicBody["output_config"] = [
                    "format": [
                        "type": "json_schema",
                        "schema": jsonSchema
                    ]
                ]
            }
            if streaming { anthropicBody["stream"] = true }
            body = anthropicBody
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func decodeContent(from data: Data, apiProtocol: CloudAPIProtocol) throws -> String {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudEngineError.malformedResponse
        }

        let content: String?
        switch apiProtocol {
        case .openAIChatCompletions:
            let choices = parsed["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            content = textContent(from: message?["content"])

        case .openAIResponses:
            if let outputText = parsed["output_text"] as? String, !outputText.isEmpty {
                content = outputText
            } else {
                let outputs = parsed["output"] as? [[String: Any]] ?? []
                let texts = outputs.flatMap { output -> [String] in
                    guard let blocks = output["content"] as? [[String: Any]] else { return [] }
                    return blocks.compactMap { block in
                        guard block["type"] as? String == "output_text" else { return nil }
                        return block["text"] as? String
                    }
                }
                content = texts.isEmpty ? nil : texts.joined()
            }

        case .anthropicMessages:
            content = textContent(from: parsed["content"])
        }

        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudEngineError.malformedResponse
        }
        return content
    }

    private static func textContent(from value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            if let text = block["text"] as? String {
                return text
            }
            if let text = block["content"] as? String {
                return text
            }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined()
    }

    func chat(
        system: String,
        user: String,
        history: [MemoryChatTurn] = [],
        jsonSchemaName: String?,
        jsonSchema: [String: Any]?
    ) async throws -> String {
        let request = try Self.makeRequest(
            apiKey: apiKey,
            endpoint: endpoint,
            model: model,
            apiProtocol: apiProtocol,
            system: system,
            user: user,
            history: history,
            jsonSchemaName: jsonSchemaName,
            jsonSchema: jsonSchema
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudEngineError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudEngineError.httpError(
                http.statusCode,
                Self.serverErrorMessage(from: data),
                requestedURL: request.url?.absoluteString
            )
        }
        return try Self.decodeContent(from: data, apiProtocol: apiProtocol)
    }

    // MARK: - 流式（SSE）

    /// 一行 SSE 解析出来的事件。
    enum CloudStreamEvent: Equatable {
        /// 一段新文本增量。
        case text(String)
        /// 服务端宣布本回合结束。
        case done
        /// 与正文无关的行（event:/id:/注释/心跳/角色块等），跳过。
        case ignored
    }

    /// 解析一行 SSE。只认 `data:` 行——`event:` 行的信息在 data 的 type 字段里
    /// 都有，认一处就够。服务端在流里报错时抛 streamFailed（带服务端原文）。
    static func parseStreamLine(
        _ line: String,
        apiProtocol: CloudAPIProtocol
    ) throws -> CloudStreamEvent {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return .ignored }
        var payload = String(trimmed.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }

        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignored
        }
        if let failure = streamErrorMessage(from: parsed) {
            throw CloudEngineError.streamFailed(failure)
        }

        switch apiProtocol {
        case .openAIChatCompletions:
            let delta = (parsed["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
            if let text = delta?["content"] as? String, !text.isEmpty {
                return .text(text)
            }
            return .ignored

        case .openAIResponses:
            switch parsed["type"] as? String {
            case "response.output_text.delta":
                if let text = parsed["delta"] as? String, !text.isEmpty {
                    return .text(text)
                }
                return .ignored
            case "response.completed", "response.incomplete":
                return .done
            default:
                return .ignored
            }

        case .anthropicMessages:
            switch parsed["type"] as? String {
            case "content_block_delta":
                let delta = parsed["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta",
                   let text = delta?["text"] as? String, !text.isEmpty {
                    return .text(text)
                }
                return .ignored
            case "message_stop":
                return .done
            default:
                return .ignored
            }
        }
    }

    /// 流内错误事件的服务端原文（OpenAI 的 {"error":…}、Anthropic 的
    /// {"type":"error",…}、Responses 的 response.failed 都盖到）。
    private static func streamErrorMessage(from parsed: [String: Any]) -> String? {
        if let error = parsed["error"] as? [String: Any] {
            return (error["message"] as? String) ?? "未知错误"
        }
        switch parsed["type"] as? String {
        case "error":
            return (parsed["message"] as? String) ?? "未知错误"
        case "response.failed":
            let response = parsed["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            return (error?["message"] as? String) ?? "response.failed"
        default:
            return nil
        }
    }

    /// 一段流式回答最多累积多少字节（UTF-8）。
    static let maxStreamedAnswerBytes = 512 * 1024
    /// 相邻两次向消费方 yield 全文的最小间隔。
    static let streamYieldInterval: Duration = .milliseconds(40)

    func streamMemoryAnswer(_ input: MemoryQuestionInput) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard isAvailable else {
                        throw MemoryAnswerError.engineUnavailable(tr("the_cloud_engine_is_not_configured"))
                    }
                    let request = try Self.makeRequest(
                        apiKey: apiKey,
                        endpoint: endpoint,
                        model: model,
                        apiProtocol: apiProtocol,
                        system: IntelligencePrompts.styled(
                            IntelligencePrompts.memoryChatInstructions,
                            adhdFriendly: adhdFriendlyOutput
                        ),
                        user: IntelligencePrompts.memoryChatUser(input),
                        history: IntelligencePrompts.boundedHistory(input.history),
                        jsonSchemaName: nil,
                        jsonSchema: nil,
                        streaming: true
                    )

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw CloudEngineError.malformedResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // 失败响应体不是 SSE，收下来挖服务端原文（封顶防炸）。
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        throw CloudEngineError.httpError(
                            http.statusCode,
                            Self.serverErrorMessage(from: body),
                            requestedURL: request.url?.absoluteString
                        )
                    }

                    // 消费方（对话页）拿的是「到目前为止的全文」，每次 yield 都要
                    // 拷一份全文：按增量逐次 yield 会随回答变长变成平方开销。
                    // 所以按时间节流——两次 yield 至少隔 40ms，收尾时把最后一段补上。
                    var accumulated = ""
                    var lastYield: ContinuousClock.Instant?
                    var hasUnsentText = false
                    lineLoop: for try await line in bytes.lines {
                        switch try Self.parseStreamLine(line, apiProtocol: apiProtocol) {
                        case .text(let delta):
                            accumulated += delta
                            // 封顶：一段回答不该有半兆字节。超过就是服务端失控或
                            // 恶意灌数据，掐断连接，按流内失败报出去。
                            guard accumulated.utf8.count <= Self.maxStreamedAnswerBytes else {
                                bytes.task.cancel()
                                throw CloudEngineError.streamFailed(tr("streamed_answer_exceeded_size_limit"))
                            }
                            hasUnsentText = true
                            let now = ContinuousClock.now
                            if let lastYield, now - lastYield < Self.streamYieldInterval {
                                continue
                            }
                            continuation.yield(accumulated)
                            hasUnsentText = false
                            lastYield = now
                        case .done:
                            break lineLoop
                        case .ignored:
                            continue
                        }
                    }
                    if hasUnsentText {
                        continuation.yield(accumulated)
                    }
                    guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw MemoryAnswerError.emptyAnswer
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - 引擎工厂

enum IntelligenceEngineFactory {
    static func make(preferences: IntelligencePreferences) -> IntelligenceEngineProtocol {
        switch preferences.engine {
        case .onDevice:
            #if canImport(FoundationModels) && !LIGHTANCHOR_DISABLE_FOUNDATIONMODELS
            if #available(macOS 26.0, *) {
                return FoundationModelsIntelligenceEngine(
                    adhdFriendlyOutput: preferences.adhdFriendlyOutput
                )
            }
            #endif
            return HeuristicIntelligenceEngine()
        case .cloud:
            let profile = preferences.activeCloudProfile
            return CloudIntelligenceEngine(
                apiKey: profile.apiKey,
                endpoint: profile.chatEndpoint,
                model: profile.model,
                apiProtocol: profile.apiProtocol,
                adhdFriendlyOutput: preferences.adhdFriendlyOutput
            )
        }
    }

    /// 端侧引擎是否可用（供偏好页显示状态）。
    static var onDeviceAvailable: Bool {
        #if canImport(FoundationModels) && !LIGHTANCHOR_DISABLE_FOUNDATIONMODELS
        if #available(macOS 26.0, *) {
            return FoundationModelsIntelligenceEngine().isAvailable
        }
        #endif
        return false
    }
}

// MARK: - 现场快照构建器
//
// 把 ContextCapsule（AX 采集的原始数据）转换成 SceneSnapshot（现场清单）。

enum SceneSnapshotBuilder {
    /// 从 ContextCapsule 构建现场条目列表。
    static func items(from capsule: ContextCapsule) -> [SceneItem] {
        var items: [SceneItem] = []

        // 文件
        for fileURL in capsule.files {
            items.append(SceneItem(
                kind: .file,
                title: fileURL.lastPathComponent,
                address: fileURL.absoluteString,
                sourceApplication: appName(for: fileURL, in: capsule),
                detail: ""
            ))
        }

        // 网页
        for linkURL in capsule.links {
            items.append(SceneItem(
                kind: .link,
                title: pageTitle(for: linkURL, in: capsule) ?? linkURL.host ?? linkURL.absoluteString,
                address: linkURL.absoluteString,
                sourceApplication: appName(forLink: linkURL, in: capsule)
            ))
        }

        // 终端目录（detail 带上采集瞬间正在运行的命令，如 "swift test"）
        for (index, dirURL) in capsule.terminalWorkingDirectories.enumerated() {
            let runningCommand = index < capsule.terminalCommands.count
                ? capsule.terminalCommands[index]
                : ""
            items.append(SceneItem(
                kind: .terminal,
                title: dirURL.lastPathComponent,
                address: dirURL.absoluteString,
                sourceApplication: terminalAppName(in: capsule),
                detail: runningCommand
            ))
        }

        // 应用（从 windowFacts 提取，按 bundleID 去重）
        var seenApps = Set<String>()
        for fact in capsule.windowFacts {
            let bundleID = fact.applicationBundleIdentifier
            guard !bundleID.isEmpty, !seenApps.contains(bundleID) else { continue }
            seenApps.insert(bundleID)
            let appName = appName(forBundleID: bundleID, in: capsule)
            items.append(SceneItem(
                kind: .application,
                title: appName,
                address: bundleID,
                sourceApplication: appName
            ))
        }

        return items
    }

    /// 用智能引擎筛选现场条目，生成 SceneSnapshot。
    static func buildSnapshot(
        from capsule: ContextCapsule,
        targetID: UUID?,
        targetName: String,
        targetNote: String,
        filterMode: SceneFilterMode,
        engine: IntelligenceEngineProtocol,
        generateReturnCue: Bool = true
    ) async -> SceneSnapshot {
        var items = Self.items(from: capsule)

        switch filterMode {
        case .saveAll:
            for index in items.indices {
                items[index].isRelevant = true
                items[index].relevanceSource = .all
            }
        case .aiFiltered:
            let results = await engine.filterSceneItems(
                items: items, targetName: targetName, targetNote: targetNote
            )
            // 能给出判断的只有模型：启发式和引擎的失败路径都返回空，落到下面的全部保留。
            let source: SceneRelevanceSource = .ai
            if results.isEmpty {
                // 无 AI 或引擎失败：全部保留，宁可多存不漏存
                for index in items.indices {
                    items[index].isRelevant = true
                    items[index].relevanceSource = .all
                }
            } else {
                for result in results {
                    if let index = items.firstIndex(where: { $0.id == result.itemID }) {
                        items[index].isRelevant = result.isRelevant
                        items[index].relevanceSource = source
                    }
                }
            }
        }

        let lastFile = items.first(where: { $0.kind == .file })?.title
        let lastCmd = items.first(where: { $0.kind == .terminal })?.detail
        let returnCue: String
        if generateReturnCue {
            returnCue = await engine.generateReturnCue(
                items: items, targetName: targetName,
                lastEditedFile: lastFile,
                lastTerminalCommand: (lastCmd?.isEmpty == false) ? lastCmd : nil
            )
        } else {
            returnCue = ""
        }

        return SceneSnapshot(
            targetID: targetID,
            items: items,
            filterMode: filterMode,
            returnCue: returnCue,
            clipboardText: capsule.clipboardText
        )
    }

    private static func appName(for fileURL: URL, in capsule: ContextCapsule) -> String {
        if let fact = capsule.windowFacts.first(where: { $0.documentURL == fileURL }) {
            return appName(forBundleID: fact.applicationBundleIdentifier, in: capsule)
        }
        return capsule.applications.first ?? ""
    }

    private static func appName(forLink url: URL, in capsule: ContextCapsule) -> String {
        if let fact = capsule.windowFacts.first(where: { $0.documentURL == url }) {
            return appName(forBundleID: fact.applicationBundleIdentifier, in: capsule)
        }
        return ""
    }

    private static func appName(forBundleID bundleID: String, in capsule: ContextCapsule) -> String {
        if let index = capsule.applicationBundleIdentifiers.firstIndex(of: bundleID),
           index < capsule.applications.count
        {
            return capsule.applications[index]
        }
        return bundleID
    }

    private static func terminalAppName(in capsule: ContextCapsule) -> String {
        let terminalBundleIDs: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
            "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm"
        ]
        if let index = capsule.applicationBundleIdentifiers.firstIndex(where: { terminalBundleIDs.contains($0) }),
           index < capsule.applications.count
        {
            return capsule.applications[index]
        }
        return "Terminal"
    }

    private static func pageTitle(for url: URL, in capsule: ContextCapsule) -> String? {
        capsule.windowFacts.first(where: { $0.documentURL == url })?.title
    }
}

// MARK: - 现场失效检查

enum SceneStalenessChecker {
    /// 检查单个现场条目是否已变化或失效。
    static func check(_ item: SceneItem, fileManager: FileManager = .default) -> SceneItemStaleness {
        switch item.kind {
        case .file:
            guard let url = URL(string: item.address), url.isFileURL else {
                return .missing(reason: "文件地址无效")
            }
            if !fileManager.fileExists(atPath: url.path) {
                return .missing(reason: "文件可能已被移动或删除")
            }
            return .fresh

        case .link:
            guard let url = URL(string: item.address),
                  url.scheme == "http" || url.scheme == "https" else {
                return .missing(reason: "链接格式无效")
            }
            // 不做网络请求（避免阻塞和流量），链接只校验格式
            return .fresh

        case .terminal:
            guard let url = URL(string: item.address), url.isFileURL else {
                return .missing(reason: "目录地址无效")
            }
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                return .missing(reason: "目录可能已不存在")
            }
            return .fresh

        case .application:
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.address) == nil {
                return .missing(reason: "应用可能已卸载")
            }
            return .fresh
        }
    }

    /// 批量检查。
    static func checkAll(_ items: [SceneItem], fileManager: FileManager = .default) -> [UUID: SceneItemStaleness] {
        var results: [UUID: SceneItemStaleness] = [:]
        for item in items {
            results[item.id] = check(item, fileManager: fileManager)
        }
        return results
    }
}
