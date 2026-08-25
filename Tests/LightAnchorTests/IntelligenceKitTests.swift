import Foundation
import XCTest
@testable import LightAnchor

final class IntelligenceKitTests: XCTestCase {

    // MARK: - 启发式不猜

    func testHeuristicFilterDeclinesToJudge() async {
        let engine = HeuristicIntelligenceEngine()
        let items = [
            SceneItem(kind: .file, title: "product-plan.md", address: "file:///tmp/product-plan.md"),
            SceneItem(kind: .terminal, title: "light-anchor", address: "file:///tmp/light-anchor"),
            SceneItem(kind: .application, title: "Music", address: "com.apple.Music", sourceApplication: "Music")
        ]
        // 相关性先验已取消：返回空＝无法判断，buildSnapshot 会全部保留。
        let results = await engine.filterSceneItems(
            items: items,
            targetName: "写代码",
            targetNote: ""
        )
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - 回来先做

    func testReturnCuePrefersFileAndCommand() async {
        let engine = HeuristicIntelligenceEngine()
        let cue = await engine.generateReturnCue(
            items: [],
            targetName: "写方案",
            lastEditedFile: "/tmp/plan.md",
            lastTerminalCommand: "swift test"
        )
        XCTAssertTrue(cue.contains("plan.md"))
        XCTAssertTrue(cue.contains("swift test"))
    }

    func testReturnCueFallsBackToFirstFile() async {
        let engine = HeuristicIntelligenceEngine()
        let file = SceneItem(kind: .file, title: "notes.md", address: "file:///tmp/notes.md")
        let cue = await engine.generateReturnCue(
            items: [file],
            targetName: "整理笔记",
            lastEditedFile: nil,
            lastTerminalCommand: nil
        )
        XCTAssertTrue(cue.contains("notes.md"))
    }

    func testReturnCueFallsBackToTargetName() async {
        let engine = HeuristicIntelligenceEngine()
        let cue = await engine.generateReturnCue(
            items: [],
            targetName: "写作",
            lastEditedFile: nil,
            lastTerminalCommand: nil
        )
        XCTAssertTrue(cue.contains("写作"))
    }

    // MARK: - 引擎工厂

    func testFactoryReturnsCloudEngineWithCredentials() {
        var prefs = IntelligencePreferences.default
        prefs.engine = .cloud
        prefs.activeCloudProfile.apiKey = "sk-test"
        let engine = IntelligenceEngineFactory.make(preferences: prefs)
        XCTAssertTrue(engine is CloudIntelligenceEngine)
    }

    func testFactoryReturnsEngineForOnDevicePreference() {
        var prefs = IntelligencePreferences.default
        prefs.engine = .onDevice
        let engine = IntelligenceEngineFactory.make(preferences: prefs)
        // macOS 26+ 返回 FoundationModels 引擎（模型未就绪时 isAvailable 为 false，
        // 事实拼装类能力降级启发式，判断类返回空由调用方保留全部）；
        // 旧系统直接返回启发式。两种都合法。
        if #available(macOS 26.0, *) {
            XCTAssertFalse(engine.name.isEmpty)
        } else {
            XCTAssertTrue(engine is HeuristicIntelligenceEngine)
        }
    }

    // MARK: - 云端引擎

    func testDefaultPreferencesUseCloudEnhancementAsPrimary() {
        let preferences = IntelligencePreferences.default

        XCTAssertEqual(preferences.engine, .cloud)
        // 开箱就有一套方案，而且是使用中的那套：没有「零方案」状态。
        XCTAssertEqual(preferences.cloudProfiles.count, 1)
        XCTAssertEqual(preferences.activeCloudProfileID, preferences.cloudProfiles[0].id)

        let profile = preferences.activeCloudProfile
        XCTAssertEqual(profile.provider, .openAI)
        XCTAssertEqual(profile.apiProtocol, .openAIChatCompletions)
        XCTAssertEqual(profile.chatEndpoint, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(profile.effectiveModelsEndpoint, "https://api.openai.com/v1/models")
        XCTAssertEqual(profile.model, "gpt-5.6-luna")
        XCTAssertTrue(profile.apiKey.isEmpty)
    }

    func testCloudServicePresetsIncludeMainstreamProviders() {
        let providers = Set(CloudServicePreset.allCases)

        XCTAssertTrue(providers.contains(.openAI))
        XCTAssertTrue(providers.contains(.anthropic))
        XCTAssertTrue(providers.contains(.deepSeek))
        XCTAssertTrue(providers.contains(.openRouter))
        XCTAssertTrue(providers.contains(.siliconFlow))
        XCTAssertTrue(providers.contains(.moonshot))
        XCTAssertTrue(providers.contains(.groq))
        XCTAssertTrue(providers.contains(.together))
        XCTAssertTrue(providers.contains(.custom))
    }

    func testCloudServicePresetProvidesEndpointAndModels() {
        XCTAssertEqual(CloudServicePreset.deepSeek.chatEndpoint, "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(CloudServicePreset.deepSeek.modelsEndpoint, "https://api.deepseek.com/v1/models")
        XCTAssertEqual(CloudServicePreset.deepSeek.defaultModel, "deepseek-chat")
        XCTAssertTrue(CloudServicePreset.openRouter.recommendedModels.contains("openai/gpt-5-mini"))
        XCTAssertFalse(CloudServicePreset.siliconFlow.recommendedModels.isEmpty)
    }

    func testCloudProtocolsMatchProviderDefaults() {
        XCTAssertEqual(CloudServicePreset.openAI.defaultAPIProtocol, .openAIChatCompletions)
        XCTAssertTrue(CloudServicePreset.openAI.supportedAPIProtocols.contains(.openAIResponses))
        XCTAssertEqual(CloudServicePreset.anthropic.defaultAPIProtocol, .anthropicMessages)
        XCTAssertEqual(CloudServicePreset.deepSeek.supportedAPIProtocols, [.openAIChatCompletions])
        XCTAssertEqual(CloudServicePreset.custom.supportedAPIProtocols, CloudAPIProtocol.allCases)
    }

    func testProtocolSpecificPresetEndpoints() {
        XCTAssertEqual(
            CloudServicePreset.openAI.endpoint(for: .openAIResponses),
            "https://api.openai.com/v1/responses"
        )
        XCTAssertEqual(
            CloudServicePreset.anthropic.endpoint(for: .anthropicMessages),
            "https://api.anthropic.com/v1/messages"
        )
    }

    func testCloudConfigurationRejectsIncompleteValues() {
        // Key 为空是合法配置：免鉴权的网关/本地服务照样能发请求。
        XCTAssertEqual(
            CloudConnectionConfiguration(
                apiKey: "",
                chatEndpoint: "https://api.openai.com/v1/chat/completions",
                modelsEndpoint: "https://api.openai.com/v1/models",
                model: "gpt-5.6-luna"
            ).status,
            .ready
        )
        XCTAssertEqual(
            CloudConnectionConfiguration(
                apiKey: "sk-test",
                chatEndpoint: "not-an-url",
                modelsEndpoint: "",
                model: "gpt-5.6-luna"
            ).status,
            .invalidEndpoint
        )
        XCTAssertEqual(
            CloudConnectionConfiguration(
                apiKey: "sk-test",
                chatEndpoint: "https://api.openai.com/v1/chat/completions",
                modelsEndpoint: "",
                model: ""
            ).status,
            .missingModel
        )
    }

    func testCloudConfigurationNormalizesEndpointAndBuildsRoutes() throws {
        let configuration = CloudConnectionConfiguration(
            apiKey: "sk-test",
            chatEndpoint: "https://api.example.com/custom/chat",
            modelsEndpoint: "https://api.example.com/custom/catalog",
            model: "gpt-5.6-luna"
        )

        XCTAssertEqual(configuration.status, .ready)
        XCTAssertEqual(configuration.normalizedChatEndpoint, "https://api.example.com/custom/chat")
        XCTAssertEqual(configuration.normalizedModelsEndpoint, "https://api.example.com/custom/catalog")
        XCTAssertEqual(configuration.modelsURL?.absoluteString, "https://api.example.com/custom/catalog")
        XCTAssertEqual(configuration.chatURL?.absoluteString, "https://api.example.com/custom/chat")
    }

    func testModelsEndpointDerivedFromChatEndpoint() {
        XCTAssertEqual(
            CloudConnectionConfiguration.deriveModelsEndpoint(
                fromChatEndpoint: "https://api.example.com/v1/chat/completions"
            ),
            "https://api.example.com/v1/models"
        )
        XCTAssertEqual(
            CloudConnectionConfiguration.deriveModelsEndpoint(
                fromChatEndpoint: "https://api.anthropic.com/v1/messages"
            ),
            "https://api.anthropic.com/v1/models"
        )
        XCTAssertEqual(
            CloudConnectionConfiguration.deriveModelsEndpoint(
                fromChatEndpoint: "https://api.openai.com/v1/responses"
            ),
            "https://api.openai.com/v1/models"
        )
        // 未知路径：把最后一段换成 models。
        XCTAssertEqual(
            CloudConnectionConfiguration.deriveModelsEndpoint(
                fromChatEndpoint: "https://api.example.com/custom/chat"
            ),
            "https://api.example.com/custom/models"
        )
        XCTAssertNil(
            CloudConnectionConfiguration.deriveModelsEndpoint(fromChatEndpoint: "not-an-url")
        )
    }

    func testEffectiveModelsEndpointUsesPresetThenDerivation() {
        var preferences = IntelligencePreferences.default
        XCTAssertEqual(
            preferences.activeCloudProfile.effectiveModelsEndpoint,
            "https://api.openai.com/v1/models"
        )

        preferences.activeCloudProfile.provider = .custom
        preferences.activeCloudProfile.chatEndpoint = "https://my-proxy.example/v1/chat/completions"
        XCTAssertEqual(
            preferences.activeCloudProfile.effectiveModelsEndpoint,
            "https://my-proxy.example/v1/models"
        )
    }

    func testServerErrorMessageParsesCompatibleErrorBodies() {
        let openAIBody = #"{"error":{"message":"The model `x` does not exist","type":"invalid_request_error"}}"#
        XCTAssertEqual(
            CloudIntelligenceEngine.serverErrorMessage(from: Data(openAIBody.utf8)),
            "The model `x` does not exist"
        )
        let plainBody = #"{"message":"not found"}"#
        XCTAssertEqual(
            CloudIntelligenceEngine.serverErrorMessage(from: Data(plainBody.utf8)),
            "not found"
        )
        XCTAssertNil(CloudIntelligenceEngine.serverErrorMessage(from: Data("<html>".utf8)))
    }

    func testCloudModelCatalogParsesAndSortsModelIDs() throws {
        let payload = #"{"data":[{"id":"gpt-4o-mini"},{"id":"gpt-5.6-luna"},{"id":"gpt-4o-mini"}]}"#
        let modelIDs = try CloudModelCatalog.decodeModelIDs(from: Data(payload.utf8))

        XCTAssertEqual(modelIDs, ["gpt-4o-mini", "gpt-5.6-luna"])
    }

    func testCloudEngineUnavailableWithoutCredentials() {
        let engine = CloudIntelligenceEngine(apiKey: "", endpoint: "", model: "gpt-5.6-luna")
        XCTAssertFalse(engine.isAvailable)
    }

    func testCloudEngineTrimsTrailingSlashInEndpoint() {
        let engine = CloudIntelligenceEngine(
            apiKey: "sk-test",
            endpoint: "https://api.example.com/custom/chat/",
            model: "gpt-5.6-luna"
        )
        XCTAssertTrue(engine.isAvailable)
        XCTAssertEqual(engine.endpoint, "https://api.example.com/custom/chat")
    }

    /// 各家文档给的都是基地址（…/v1）：照原样 POST 只会拿回 404，
    /// 缺的请求路径由我们补齐。
    func testCloudEngineCompletesBaseURLIntoRequestPath() {
        let chat = CloudIntelligenceEngine(
            apiKey: "sk-test",
            endpoint: "https://opencode.ai/zen/v1",
            model: "mimo-v2.5-free"
        )
        XCTAssertEqual(chat.endpoint, "https://opencode.ai/zen/v1/chat/completions")

        let responses = CloudIntelligenceEngine(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/",
            model: "gpt-5.6-luna",
            apiProtocol: .openAIResponses
        )
        XCTAssertEqual(responses.endpoint, "https://api.openai.com/v1/responses")

        let anthropic = CloudIntelligenceEngine(
            apiKey: "sk-test",
            endpoint: "https://api.anthropic.com",
            model: "claude-sonnet-5",
            apiProtocol: .anthropicMessages
        )
        XCTAssertEqual(anthropic.endpoint, "https://api.anthropic.com/v1/messages")
    }

    /// 已经是完整请求路径、或是这家服务自己的路由：一个字都不许改。
    func testCloudEngineLeavesRealRequestPathsAlone() {
        for (endpoint, apiProtocol) in [
            ("https://api.openai.com/v1/chat/completions", CloudAPIProtocol.openAIChatCompletions),
            ("https://gateway.example.com/api/chat", CloudAPIProtocol.openAIChatCompletions),
            ("https://api.anthropic.com/v1/messages", CloudAPIProtocol.anthropicMessages)
        ] {
            let engine = CloudIntelligenceEngine(
                apiKey: "sk-test",
                endpoint: endpoint,
                model: "m",
                apiProtocol: apiProtocol
            )
            XCTAssertEqual(engine.endpoint, endpoint)
        }
    }

    /// 基地址方案的模型列表端点也要从补齐后的地址推导。
    func testProfileWithBaseURLResolvesEndpointAndModelList() {
        let profile = CloudProviderProfile(
            name: "opencode zen",
            provider: .custom,
            apiProtocol: .openAIChatCompletions,
            apiKey: "sk-test",
            chatEndpoint: "https://opencode.ai/zen/v1",
            model: "mimo-v2.5-free"
        )
        XCTAssertEqual(profile.resolvedChatEndpoint, "https://opencode.ai/zen/v1/chat/completions")
        XCTAssertEqual(profile.effectiveModelsEndpoint, "https://opencode.ai/zen/v1/models")
        XCTAssertEqual(profile.status, .ready)
    }

    /// 404 报错要带上真正请求过的地址，否则没法对照排查。
    func testCloudHTTPErrorMentionsRequestedURL() {
        let error = CloudIntelligenceEngine.CloudEngineError.httpError(
            404,
            nil,
            requestedURL: "https://opencode.ai/zen/v1/chat/completions"
        )
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("404"))
        XCTAssertTrue(description.contains("https://opencode.ai/zen/v1/chat/completions"))
    }

    func testCloudEngineStoresSelectedProtocol() {
        let engine = CloudIntelligenceEngine(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/responses",
            model: "gpt-5.6-luna",
            apiProtocol: .openAIResponses
        )

        XCTAssertEqual(engine.apiProtocol, .openAIResponses)
        XCTAssertTrue(engine.isAvailable)
    }

    func testCloudRequestBuildsOpenAIChatCompletionsPayload() throws {
        let request = try CloudIntelligenceEngine.makeRequest(
            apiKey: "sk-test",
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "model-chat",
            apiProtocol: .openAIChatCompletions,
            system: "system prompt",
            user: "user prompt",
            jsonSchemaName: "result",
            jsonSchema: ["type": "object"]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try XCTUnwrap(request.httpBody).jsonObject()
        XCTAssertEqual(body["model"] as? String, "model-chat")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(body["response_format"])
    }

    func testCloudRequestBuildsOpenAIResponsesPayload() throws {
        let request = try CloudIntelligenceEngine.makeRequest(
            apiKey: "sk-test",
            endpoint: "https://api.example.com/v1/responses",
            model: "model-responses",
            apiProtocol: .openAIResponses,
            system: "system prompt",
            user: "user prompt",
            jsonSchemaName: "result",
            jsonSchema: ["type": "object"]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(request.httpBody).jsonObject()
        XCTAssertEqual(body["instructions"] as? String, "system prompt")
        XCTAssertEqual(body["input"] as? String, "user prompt")
        XCTAssertNil(body["messages"])
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, "result")
    }

    func testCloudRequestBuildsAnthropicMessagesPayload() throws {
        let request = try CloudIntelligenceEngine.makeRequest(
            apiKey: "anthropic-test",
            endpoint: "https://api.example.com/v1/messages",
            model: "claude-test",
            apiProtocol: .anthropicMessages,
            system: "system prompt",
            user: "user prompt",
            jsonSchemaName: "result",
            jsonSchema: ["type": "object"]
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(request.httpBody).jsonObject()
        XCTAssertEqual(body["system"] as? String, "system prompt")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1)
        XCTAssertNotNil(body["max_tokens"])
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
    }

    func testCloudResponseParsersHandleAllThreeProtocols() throws {
        let chat = #"{"choices":[{"message":{"content":"chat result"}}]}"#
        XCTAssertEqual(
            try CloudIntelligenceEngine.decodeContent(from: Data(chat.utf8), apiProtocol: .openAIChatCompletions),
            "chat result"
        )

        let responses = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"responses result"}]}]}"#
        XCTAssertEqual(
            try CloudIntelligenceEngine.decodeContent(from: Data(responses.utf8), apiProtocol: .openAIResponses),
            "responses result"
        )

        let anthropic = #"{"content":[{"type":"text","text":"anthropic result"}]}"#
        XCTAssertEqual(
            try CloudIntelligenceEngine.decodeContent(from: Data(anthropic.utf8), apiProtocol: .anthropicMessages),
            "anthropic result"
        )
    }

    func testCloudEngineUnavailableWithoutModel() {
        let engine = CloudIntelligenceEngine(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: ""
        )

        XCTAssertFalse(engine.isAvailable)
    }

    // MARK: - 多轮（真实 messages 数组）

    func testCloudRequestSendsHistoryAsRealMessages() throws {
        let history = [
            MemoryChatTurn(role: .user, text: "上周在忙什么？"),
            MemoryChatTurn(role: .assistant, text: "上周主要在做蓝点重构。")
        ]

        let chat = try CloudIntelligenceEngine.makeRequest(
            apiKey: "sk-test",
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "m",
            apiProtocol: .openAIChatCompletions,
            system: "system prompt",
            user: "当轮问题",
            history: history,
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        let chatMessages = try XCTUnwrap(
            try XCTUnwrap(chat.httpBody).jsonObject()["messages"] as? [[String: Any]]
        )
        XCTAssertEqual(
            chatMessages.map { $0["role"] as? String },
            ["system", "user", "assistant", "user"]
        )
        XCTAssertEqual(chatMessages[2]["content"] as? String, "上周主要在做蓝点重构。")
        XCTAssertEqual(chatMessages.last?["content"] as? String, "当轮问题")

        let anthropic = try CloudIntelligenceEngine.makeRequest(
            apiKey: "anthropic-test",
            endpoint: "https://api.example.com/v1/messages",
            model: "m",
            apiProtocol: .anthropicMessages,
            system: "system prompt",
            user: "当轮问题",
            history: history,
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        let anthropicBody = try XCTUnwrap(anthropic.httpBody).jsonObject()
        XCTAssertEqual(anthropicBody["system"] as? String, "system prompt")
        let anthropicMessages = try XCTUnwrap(anthropicBody["messages"] as? [[String: Any]])
        XCTAssertEqual(
            anthropicMessages.map { $0["role"] as? String },
            ["user", "assistant", "user"]
        )

        let responses = try CloudIntelligenceEngine.makeRequest(
            apiKey: "sk-test",
            endpoint: "https://api.example.com/v1/responses",
            model: "m",
            apiProtocol: .openAIResponses,
            system: "system prompt",
            user: "当轮问题",
            history: history,
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        let responsesInput = try XCTUnwrap(
            try XCTUnwrap(responses.httpBody).jsonObject()["input"] as? [[String: Any]]
        )
        XCTAssertEqual(
            responsesInput.map { $0["role"] as? String },
            ["user", "assistant", "user"]
        )
    }

    func testBoundedHistoryProducesLegalAlternation() {
        // 开头的孤儿回答、结尾没有回答的孤儿提问都剪掉；
        // 相邻同角色合并（出错回合被剔除后会出现相邻提问）。
        let turns = [
            MemoryChatTurn(role: .assistant, text: "旧回答"),
            MemoryChatTurn(role: .user, text: "问一"),
            MemoryChatTurn(role: .assistant, text: "答一"),
            MemoryChatTurn(role: .user, text: "问二"),
            MemoryChatTurn(role: .user, text: "问二补充"),
            MemoryChatTurn(role: .assistant, text: "答二"),
            MemoryChatTurn(role: .user, text: "孤儿提问")
        ]
        let bounded = IntelligencePrompts.boundedHistory(turns)
        XCTAssertEqual(bounded.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(bounded[1].text, "答一")
        XCTAssertEqual(bounded[2].text, "问二\n问二补充")
        XCTAssertEqual(bounded[3].text, "答二")
    }

    func testBoundedHistoryKeepsNewestWithinBudgetAndClipsLongMessages() {
        let long = String(repeating: "长", count: 2000)
        let turns = [
            MemoryChatTurn(role: .user, text: "很早的问题"),
            MemoryChatTurn(role: .assistant, text: long),
            MemoryChatTurn(role: .user, text: "新问题"),
            MemoryChatTurn(role: .assistant, text: "新回答")
        ]
        // 预算从最新往回收：装不下的旧轮先丢。
        let bounded = IntelligencePrompts.boundedHistory(turns, perMessageLimit: 100, totalLimit: 100)
        XCTAssertEqual(bounded.map(\.text), ["新问题", "新回答"])

        // 单条超长截尾并标记（保留开头：问答的信息密度前重后轻）。
        let clipped = IntelligencePrompts.boundedHistory(
            [
                MemoryChatTurn(role: .user, text: long),
                MemoryChatTurn(role: .assistant, text: "答")
            ],
            perMessageLimit: 100,
            totalLimit: 6000
        )
        XCTAssertEqual(clipped.first?.text.count, 101)
        XCTAssertEqual(clipped.first?.text.hasSuffix("…"), true)
    }

    // MARK: - 流式（SSE）

    func testCloudRequestStreamingFlagOnlyWhenAsked() throws {
        let plain = try CloudIntelligenceEngine.makeRequest(
            apiKey: "sk-test",
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "m",
            apiProtocol: .openAIChatCompletions,
            system: "s",
            user: "u",
            jsonSchemaName: nil,
            jsonSchema: nil
        )
        XCTAssertNil(try XCTUnwrap(plain.httpBody).jsonObject()["stream"])
        XCTAssertEqual(plain.timeoutInterval, 30)

        let streaming = try CloudIntelligenceEngine.makeRequest(
            apiKey: "sk-test",
            endpoint: "https://api.example.com/v1/chat/completions",
            model: "m",
            apiProtocol: .openAIChatCompletions,
            system: "s",
            user: "u",
            jsonSchemaName: nil,
            jsonSchema: nil,
            streaming: true
        )
        XCTAssertEqual(try XCTUnwrap(streaming.httpBody).jsonObject()["stream"] as? Bool, true)
        XCTAssertEqual(streaming.timeoutInterval, 180)
    }

    func testStreamLineParsingPerProtocol() throws {
        // OpenAI Chat Completions：delta 正文、[DONE]、纯角色块。
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                #"data: {"choices":[{"delta":{"content":"你"}}]}"#,
                apiProtocol: .openAIChatCompletions
            ),
            .text("你")
        )
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                "data: [DONE]", apiProtocol: .openAIChatCompletions
            ),
            .done
        )
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
                apiProtocol: .openAIChatCompletions
            ),
            .ignored
        )

        // 与正文无关的行一律跳过。
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                "event: content_block_delta", apiProtocol: .anthropicMessages
            ),
            .ignored
        )
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(": ping", apiProtocol: .openAIChatCompletions),
            .ignored
        )
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine("", apiProtocol: .openAIChatCompletions),
            .ignored
        )

        // Anthropic：text_delta 正文、message_stop 收尾、非文本 delta 跳过。
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"好"}}"#,
                apiProtocol: .anthropicMessages
            ),
            .text("好")
        )
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                #"data: {"type":"message_stop"}"#, apiProtocol: .anthropicMessages
            ),
            .done
        )
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"…"}}"#,
                apiProtocol: .anthropicMessages
            ),
            .ignored
        )

        // OpenAI Responses：output_text.delta 正文、completed 收尾。
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                #"data: {"type":"response.output_text.delta","delta":"答"}"#,
                apiProtocol: .openAIResponses
            ),
            .text("答")
        )
        XCTAssertEqual(
            try CloudIntelligenceEngine.parseStreamLine(
                #"data: {"type":"response.completed"}"#, apiProtocol: .openAIResponses
            ),
            .done
        )
    }

    func testStreamLineErrorEventsThrowWithServerText() {
        XCTAssertThrowsError(try CloudIntelligenceEngine.parseStreamLine(
            #"data: {"error":{"message":"rate limited"}}"#,
            apiProtocol: .openAIChatCompletions
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("rate limited"))
        }
        XCTAssertThrowsError(try CloudIntelligenceEngine.parseStreamLine(
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            apiProtocol: .anthropicMessages
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Overloaded"))
        }
        XCTAssertThrowsError(try CloudIntelligenceEngine.parseStreamLine(
            #"data: {"type":"response.failed","response":{"error":{"message":"quota exceeded"}}}"#,
            apiProtocol: .openAIResponses
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("quota exceeded"))
        }
    }

    func testDefaultStreamYieldsWholeAnswerOnce() async throws {
        // 不支持流式的引擎走协议默认实现：完整回答一次性产出，语义不变。
        let engine = HeuristicIntelligenceEngine()
        let input = MemoryQuestionInput(
            question: "q", periodTitle: "今天", factLines: ["[账本] x"]
        )
        var chunks: [String] = []
        for try await chunk in engine.streamMemoryAnswer(input) {
            chunks.append(chunk)
        }
        let full = await engine.answerMemoryQuestion(input)
        XCTAssertEqual(chunks, [full])
    }

    func testCloudStreamThrowsWhenUnavailableInsteadOfSilentFallback() async {
        let engine = CloudIntelligenceEngine(
            apiKey: "",
            endpoint: "https://example.com/v1/chat/completions",
            model: ""
        )
        do {
            for try await _ in engine.streamMemoryAnswer(
                MemoryQuestionInput(question: "q", periodTitle: "今天", factLines: [])
            ) {}
            XCTFail("未配置的云端引擎流式提问也应该抛错")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("还没配置好"),
                "错误要说清原因：\(error.localizedDescription)"
            )
        }
    }

}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}
