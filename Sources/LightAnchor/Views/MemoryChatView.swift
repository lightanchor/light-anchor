import SwiftUI

// MARK: - 「对话」页：问问你的记忆
//
// 形态参照桌面聊天的成熟范式：用户气泡靠右（水洗蓝底），回答是左侧正文；
// 回答上方一行可折叠的元信息（思考时长 · 依据条数 · 引擎署名），展开是
// 检索到的事实行——每个回答都能核对它依据了什么。引擎降级到哪个就署谁的名。

@MainActor
final class MemoryChatController: ObservableObject {
    @Published private(set) var messages: [MemoryChatMessage] = []
    @Published private(set) var isThinking = false
    /// 正在流式生长的那条回答；nil 且 isThinking 表示首段字还没到（界面转圈）。
    @Published private(set) var streamingMessageID: UUID?
    /// 存档读写失败的原文。对话本身出错是气泡里的错误正文，这条是「盘上那份
    /// 存档现在有问题」——两件事分开显示，都不静默。
    @Published private(set) var storageError: String?

    private let store: MemoryChatStore
    private var loaded = false
    private var currentTask: Task<Void, Never>?

    init(store: MemoryChatStore = MemoryChatStore()) {
        self.store = store
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        do {
            messages = try store.load()
            storageError = nil
            backfillChatIndex()
        } catch {
            // 读不出来就从空对话开始，但要说出来：盘上的存档还在，别默默盖掉。
            messages = []
            storageError = String(format: tr("chat_history_couldn_t_be_read"), error.localizedDescription)
            LocalDiagnostics.shared.record(
                operation: "memory-chat.load",
                message: error.localizedDescription
            )
        }
    }

    func dismissStorageError() {
        storageError = nil
    }

    func clear() {
        messages = []
        persist()
    }

    func ask(_ question: String, workspace: AttentionWorkspace) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }

        let history = recentHistory()
        messages.append(MemoryChatMessage(role: .user, text: trimmed))
        persist()
        isThinking = true

        let engine = workspace.intelligenceEngine
        let started = Date()

        currentTask = Task { @MainActor in
            defer {
                isThinking = false
                streamingMessageID = nil
                currentTask = nil
            }
            // 检索也算「正在回忆」：活状态本地拼装，历史召回走索引（FTS5+向量），
            // 追问先按需改写。
            let context = await workspace.makeChatQuestionContext(
                question: trimmed, history: history
            )
            let input = MemoryQuestionInput(
                question: trimmed,
                periodTitle: context.periodTitle,
                factLines: context.factLines,
                history: history
            )
            // 有错误就显示错误：不做本地兜底、不冒名降级（用户定）。
            do {
                for try await answerSoFar in engine.streamMemoryAnswer(input) {
                    upsertStreamingMessage(
                        text: answerSoFar,
                        engineName: engine.name,
                        factLines: context.factLines,
                        periodTitle: context.periodTitle
                    )
                }
                if let finished = finalizeStreamingMessage(started: started, interrupted: false) {
                    // 焦点还在输入框：回答/报错落地时旁白用户需要被告知，
                    // 否则不知道答案何时来、来的是答案还是错误。
                    AccessibilityNotification.Announcement(finished.text).post()
                    // 这轮问答进检索索引，之后「上次聊过什么」也搜得到。后台，不打断。
                    let turn = (id: finished.id, question: trimmed,
                                answer: finished.text, at: finished.createdAt)
                    Task.detached(priority: .utility) {
                        await MemoryIndex.shared.indexChatTurns([turn])
                    }
                } else {
                    // 流正常收尾却一个字没给：按空回答报错（引擎侧一般已拦住）。
                    appendFinishedMessage(MemoryChatMessage(
                        role: .assistant,
                        text: MemoryAnswerError.emptyAnswer.localizedDescription,
                        engineName: engine.name,
                        thinkingSeconds: Date().timeIntervalSince(started),
                        factLines: context.factLines,
                        periodTitle: context.periodTitle,
                        isError: true
                    ))
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    // 用户手动停止：留住已产出的部分并标「已中断」；一个字没来就只收场。
                    if finalizeStreamingMessage(started: started, interrupted: true) != nil {
                        AccessibilityNotification.Announcement(tr("answer_interrupted")).post()
                    }
                } else {
                    // 流中途失败：半截回答标「已中断」留下，错误原文单独一条（可重试）。
                    finalizeStreamingMessage(started: started, interrupted: true)
                    let failure = MemoryChatMessage(
                        role: .assistant,
                        text: error.localizedDescription,
                        engineName: engine.name,
                        thinkingSeconds: Date().timeIntervalSince(started),
                        factLines: context.factLines,
                        periodTitle: context.periodTitle,
                        isError: true
                    )
                    appendFinishedMessage(failure)
                    AccessibilityNotification.Announcement(failure.text).post()
                }
            }
        }
    }

    /// 停止正在生成的回答；流式请求随任务取消一并中断。
    func cancel() {
        currentTask?.cancel()
    }

    /// 重试一条出错回答：找到它前面最近的提问，原样再问一次。
    func retry(errorMessage: MemoryChatMessage, workspace: AttentionWorkspace) {
        guard let index = messages.firstIndex(where: { $0.id == errorMessage.id }) else { return }
        let question = messages[..<index].last { $0.role == .user }?.text
        guard let question else { return }
        ask(question, workspace: workspace)
    }

    /// 近几轮问答原文（最多 12 条），出错回合剔除。这里只负责取材，
    /// 预算与交替性裁剪在引擎侧（云端 boundedHistory / 端侧折叠版）。
    private func recentHistory() -> [MemoryChatTurn] {
        messages.suffix(12).compactMap { message in
            guard !message.isError else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let role: MemoryChatTurn.Role = message.role == .user ? .user : .assistant
            return MemoryChatTurn(role: role, text: text)
        }
    }

    /// 首段字到达时立一条流式回答，其后每段只更新正文（元素是累积文本）。
    private func upsertStreamingMessage(
        text: String,
        engineName: String,
        factLines: [String],
        periodTitle: String
    ) {
        if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = text
        } else {
            let message = MemoryChatMessage(
                role: .assistant,
                text: text,
                engineName: engineName,
                factLines: factLines,
                periodTitle: periodTitle
            )
            streamingMessageID = message.id
            messages.append(message)
        }
    }

    /// 收尾流式回答：定稿正文与思考时长、打中断标记、落盘。
    /// 从没产出过字（或只产出了空白）时清掉占位并返回 nil。
    @discardableResult
    private func finalizeStreamingMessage(started: Date, interrupted: Bool) -> MemoryChatMessage? {
        guard let id = streamingMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        streamingMessageID = nil
        let trimmed = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            messages.remove(at: index)
            return nil
        }
        messages[index].text = trimmed
        messages[index].thinkingSeconds = Date().timeIntervalSince(started)
        messages[index].wasInterrupted = interrupted
        persist()
        return messages[index]
    }

    private func appendFinishedMessage(_ message: MemoryChatMessage) {
        messages.append(message)
        persist()
    }

    /// 存档里的历史问答补进检索索引（键稳定、内容哈希去重，重复调用无副作用）。
    private func backfillChatIndex() {
        var turns: [(id: UUID, question: String, answer: String, at: Date)] = []
        var pendingQuestion: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingQuestion = message.text
            case .assistant:
                guard !message.isError, let question = pendingQuestion,
                      !message.text.isEmpty else { continue }
                turns.append((message.id, question, message.text, message.createdAt))
                pendingQuestion = nil
            }
        }
        guard !turns.isEmpty else { return }
        let batch = turns
        Task.detached(priority: .utility) {
            await MemoryIndex.shared.indexChatTurns(batch)
        }
    }

    private func persist() {
        do {
            try store.save(messages)
            storageError = nil
        } catch {
            storageError = String(format: tr("chat_history_couldn_t_be_saved"), error.localizedDescription)
            LocalDiagnostics.shared.record(
                operation: "memory-chat.save",
                message: error.localizedDescription
            )
        }
    }
}

struct MemoryChatView: View {
    @EnvironmentObject private var workspace: AttentionWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var controller = MemoryChatController()
    @State private var draft = ""
    @State private var expandedMessageIDs: Set<UUID> = []
    @State private var showingClearConfirm = false
    @FocusState private var inputFocused: Bool

    private static let bottomAnchor = "memory-chat-bottom"
    /// 长行也别铺满整个舞台：正文列宽与参考形态一致。
    private static let columnWidth: CGFloat = 720

    private let sampleQuestions = [
        tr("how_long_did_i_focus_today"),
        tr("what_was_i_mostly_working_on"),
        tr("what_results_am_i_waiting_on")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 标题行贴窗顶，顶替全局工具行（用户定）：侧栏开关 + 标题 + 清空。
            // 高度与内边距和 islandToolbar 完全一致，切页时开关钮不跳位。
            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .lightAnchorToggleSidebar, object: nil)
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(LightAnchorToolbarIconButtonStyle())
                .help(tr("toggle_sidebar_s"))
                .accessibilityLabel(tr("toggle_sidebar"))

                Text(tr("chat"))
                    .font(LightAnchorTheme.interfaceFont(size: 15, weight: .semibold))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(tr("ask_your_memory_answers_only_use"))
                    .font(LightAnchorTheme.supportingFont(size: 12.5))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                if !controller.messages.isEmpty {
                    Button(tr("clear_conversation")) {
                        showingClearConfirm = true
                    }
                    .buttonStyle(LightAnchorDestructiveQuietButtonStyle(compact: true))
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .confirmationDialog(
                tr("clear_this_conversation"),
                isPresented: $showingClearConfirm,
                titleVisibility: .visible
            ) {
                Button(tr("clear_conversation"), role: .destructive) {
                    controller.clear()
                    expandedMessageIDs = []
                }
                Button(UserFacingCopy.cancel, role: .cancel) {}
            } message: {
                Text(tr("chat_history_delete_note"))
            }

            if let storageError = controller.storageError {
                storageWarningStrip(storageError)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if controller.messages.isEmpty && !controller.isThinking {
                            emptyState
                        } else {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(controller.messages) { message in
                                    messageRow(message)
                                }
                                // 首段字到达后回答气泡自己就是进度，转圈只管「等首字」。
                                if controller.isThinking && controller.streamingMessageID == nil {
                                    thinkingRow
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.bottomAnchor)
                            }
                        }
                    }
                    .frame(maxWidth: Self.columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
                    .padding(.vertical, 16)
                }
                .onChange(of: controller.messages.count) { _, _ in
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: controller.isThinking) { _, _ in
                    scrollToBottom(proxy, animated: true)
                }
                // 流式正文在长，条数不变也要跟着滚（不加动画：更新太密）。
                .onChange(of: controller.messages.last?.text) { _, _ in
                    guard controller.streamingMessageID != nil else { return }
                    scrollToBottom(proxy, animated: false)
                }
                .onAppear {
                    controller.loadIfNeeded()
                    scrollToBottom(proxy, animated: false)
                    inputFocused = true
                    // 进对话页刷新一轮检索索引（60 秒节流在索引侧）。
                    workspace.refreshMemoryIndex()
                }
            }

            inputBar
                .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
                .padding(.bottom, 16)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(LightAnchorTheme.ink)
        .background(LightAnchorTheme.contentBackground)
    }

    /// 存档读写出问题时的提示条。放在标题行下面、对话之上：说清「这一轮答得
    /// 出来，但存不下／读不出来」，而不是让人以为历史自己没了。
    private func storageWarningStrip(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.dangerText)
            Text(message)
                .font(LightAnchorTheme.supportingFont(size: 12.5))
                .foregroundStyle(LightAnchorTheme.ink)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(tr("got_it")) { controller.dismissStorageError() }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LightAnchorTheme.dangerText.opacity(0.08))
        )
        .padding(.horizontal, LightAnchorDesign.workspaceHorizontalPadding)
        .padding(.bottom, 4)
    }

    // MARK: - 消息行

    @ViewBuilder
    private func messageRow(_ message: MemoryChatMessage) -> some View {
        switch message.role {
        case .user: userRow(message)
        case .assistant: assistantRow(message)
        }
    }

    private func userRow(_ message: MemoryChatMessage) -> some View {
        HStack(alignment: .top) {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 5) {
                // 参考形态：浅水洗蓝、松内距；右下角收小（气泡的「说话」方向）。
                Text(message.text)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(
                        LightAnchorTheme.accentWash.opacity(0.62),
                        in: UnevenRoundedRectangle(
                            cornerRadii: RectangleCornerRadii(
                                topLeading: 18,
                                bottomLeading: 18,
                                bottomTrailing: 6,
                                topTrailing: 18
                            ),
                            style: .continuous
                        )
                    )
                HStack(spacing: 8) {
                    Text(timeText(message.createdAt))
                        .font(LightAnchorTheme.supportingFont(size: 11))
                    // 命中区补到 24pt（原来只有字形本身 ~12pt，相邻两枚极易误触）；
                    // .help 只映射 tooltip，可及名称另给。
                    Button {
                        draft = message.text
                        inputFocused = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12, weight: .regular))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("edit_this_question_again"))
                    .accessibilityLabel(tr("edit_this_question_again"))
                    Button {
                        copyToPasteboard(message.text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11.5, weight: .regular))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("copy"))
                    .accessibilityLabel(tr("copy"))
                }
                .foregroundStyle(LightAnchorTheme.faintInk)
                .padding(.trailing, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistantRow(_ message: MemoryChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !metaText(for: message).isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                        if expandedMessageIDs.contains(message.id) {
                            expandedMessageIDs.remove(message.id)
                        } else {
                            expandedMessageIDs.insert(message.id)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .rotationEffect(.degrees(expandedMessageIDs.contains(message.id) ? 90 : 0))
                        Text(verbatim: metaText(for: message))
                            .font(LightAnchorTheme.supportingFont(size: 11.5))
                    }
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("show_the_answer_s_sources"))
            }

            if expandedMessageIDs.contains(message.id), !message.factLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(message.factLines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(LightAnchorTheme.supportingFont(size: 11.5))
                            .foregroundStyle(LightAnchorTheme.mutedInk)
                            .lineLimit(3)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(LightAnchorTheme.hairlineBorder)
                        .frame(width: 2)
                }
                .padding(.leading, 2)
            }

            Text(message.text)
                .font(LightAnchorTheme.interfaceFont(size: 13.5))
                .foregroundStyle(message.isError ? LightAnchorTheme.error : LightAnchorTheme.ink)
                .lineSpacing(3.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if message.isError {
                Button(tr("retry")) {
                    controller.retry(errorMessage: message, workspace: workspace)
                }
                .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                .disabled(controller.isThinking)
            }

            HStack(spacing: 12) {
                Text(timeText(message.createdAt))
                    .font(LightAnchorTheme.supportingFont(size: 11))
                Button {
                    copyToPasteboard(message.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .regular))
                }
                .buttonStyle(.plain)
                .help(tr("copy"))
            }
            .foregroundStyle(LightAnchorTheme.faintInk)
        }
        .padding(.trailing, 48)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(tr("recalling"))
                .font(LightAnchorTheme.supportingFont(size: 12))
                .foregroundStyle(LightAnchorTheme.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「思考了 3 秒 · 依据 12 条 · 云端增强」；出错回合换成「出错 · …」。
    /// verbatim 输出，片段各自过 tr。
    private func metaText(for message: MemoryChatMessage) -> String {
        var parts: [String] = []
        if message.wasInterrupted {
            parts.append(tr("answer_interrupted"))
        }
        if message.isError {
            parts.append(tr("error"))
        } else if let seconds = message.thinkingSeconds {
            parts.append(String(format: tr("thought_for_s"), max(1, Int(seconds.rounded()))))
        }
        if !message.factLines.isEmpty {
            parts.append(String(format: tr("sources"), message.factLines.count))
        }
        if let engineName = message.engineName, !engineName.isEmpty {
            parts.append(engineName)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            LightAnchorDestinationIcon(destination: .chat, size: 34)
                .foregroundStyle(LightAnchorTheme.faintInk)
            Text(tr("ask_your_memory"))
                .font(LightAnchorTheme.interfaceFont(size: 15, weight: .semibold))
                .foregroundStyle(LightAnchorTheme.ink)
            Text(tr("the_focus_ledger_waits_captures_and"))
                .font(LightAnchorTheme.supportingFont(size: 12))
                .foregroundStyle(LightAnchorTheme.mutedInk)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(sampleQuestions, id: \.self) { question in
                    Button(question) {
                        send(question)
                    }
                    .buttonStyle(LightAnchorQuietButtonStyle(compact: true))
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 88)
    }

    // MARK: - 输入区

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if engineUnavailableHint {
                Text(tr("the_selected_intelligence_engine_is_unavailable_2"))
                    .font(LightAnchorTheme.supportingFont(size: 11.5))
                    .foregroundStyle(LightAnchorTheme.mutedInk)
                    .padding(.horizontal, 4)
            }
            // 参考形态的输入盒：大圆角、输入在上、发送钮沉在右下角。
            VStack(alignment: .leading, spacing: 10) {
                TextField(tr("ask_your_memory_2"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(LightAnchorTheme.interfaceFont(size: 13.5))
                    .foregroundStyle(LightAnchorTheme.ink)
                    .focused($inputFocused)
                    .onSubmit { send(draft) }
                HStack {
                    Spacer(minLength: 0)
                    // 生成中这枚钮就是「停止」——随时能停是流式的另一半。
                    Button {
                        if controller.isThinking {
                            controller.cancel()
                        } else {
                            send(draft)
                        }
                    } label: {
                        Image(systemName: controller.isThinking ? "stop.fill" : "arrow.up")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(
                                controller.isThinking || canSend
                                    ? LightAnchorTheme.onAction : LightAnchorTheme.disabledInk
                            )
                            .frame(width: 28, height: 28)
                            .background(
                                controller.isThinking || canSend
                                    ? LightAnchorTheme.primaryAction : LightAnchorTheme.recessed,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.isThinking && !canSend)
                    .accessibilityLabel(controller.isThinking ? tr("stop_answering") : tr("send"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 11)
            .background(
                LightAnchorTheme.surface,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(LightAnchorTheme.hairlineBorder, lineWidth: 1)
            }
        }
        .frame(maxWidth: Self.columnWidth)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !controller.isThinking
    }

    /// 所选引擎不可用（云端没配 Key、端侧模型未就绪）——提前说清会降级到哪。
    private var engineUnavailableHint: Bool {
        let engine = workspace.intelligenceEngine
        return !(engine is HeuristicIntelligenceEngine) && !engine.isAvailable
    }

    // MARK: - 动作

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !controller.isThinking else { return }
        draft = ""
        controller.ask(question, workspace: workspace)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !controller.messages.isEmpty || controller.isThinking else { return }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #endif
    }
}
