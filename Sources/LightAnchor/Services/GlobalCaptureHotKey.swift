import AppKit
import Carbon.HIToolbox
import Foundation

/// 可配置的全局快捷键动作。新增动作时补 registrationID（Carbon 注册的
/// 稳定编号，不许复用）和 defaultBinding。
enum GlobalHotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case capture
    case openMainWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: tr("summon_capture_window")
        case .openMainWindow: tr("open_main_window")
        }
    }

    var detail: String {
        switch self {
        case .capture: tr("summon_the_capture_window_from_any")
        case .openMainWindow: tr("bring_the_light_anchor_window_forward")
        }
    }

    var defaultBinding: HotKeyBinding? {
        switch self {
        case .capture:
            HotKeyBinding(
                keyCode: UInt32(kVK_ANSI_N),
                carbonModifiers: UInt32(optionKey | cmdKey)
            )
        case .openMainWindow:
            nil
        }
    }

    /// Carbon EventHotKeyID.id。
    var registrationID: UInt32 {
        switch self {
        case .capture: 1
        case .openMainWindow: 2
        }
    }

    static func action(registrationID: UInt32) -> GlobalHotKeyAction? {
        allCases.first { $0.registrationID == registrationID }
    }
}

/// 一组按键：keyCode + Carbon 修饰键位。
struct HotKeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// 至少要有 ⌘ / ⌥ / ⌃ 之一：纯字符或仅 ⇧ 的全局热键会吞掉
    /// 其他应用里的正常输入。
    var hasCommandingModifier: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyCap(for: keyCode))
        return parts.joined(separator: " ")
    }

    /// 从录制到的按键事件生成（keyDown）。修饰键单独按下不构成快捷键。
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// 键帽名。按 ANSI 布局写死：全局热键按物理键位注册，
    /// 显示名跟着注册走比跟着输入法走更不误导。
    static func keyCap(for keyCode: UInt32) -> String {
        if let cap = keyCapNames[Int(keyCode)] { return cap }
        return String(format: tr("key_n"), keyCode)
    }

    private static let keyCapNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Space: tr("space_key_cap"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// 全局快捷键偏好：缺项 = 用默认值，显式清除 = 不注册。
struct GlobalHotKeyPreferences: Equatable {
    static let storageKey = "lightanchor.globalHotKeys"

    /// 只存用户改过的动作；nil 值表示「显式清除」。
    private var overrides: [GlobalHotKeyAction: HotKeyBinding?]

    init(overrides: [GlobalHotKeyAction: HotKeyBinding?] = [:]) {
        self.overrides = overrides
    }

    func binding(for action: GlobalHotKeyAction) -> HotKeyBinding? {
        if let override = overrides[action] { return override }
        return action.defaultBinding
    }

    mutating func setBinding(_ binding: HotKeyBinding?, for action: GlobalHotKeyAction) {
        if binding == action.defaultBinding {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = binding
        }
    }

    // MARK: - 持久化（UserDefaults JSON）

    private struct StoredBinding: Codable {
        var cleared: Bool?
        var keyCode: UInt32?
        var carbonModifiers: UInt32?
    }

    static func load(defaults: UserDefaults = .standard) -> GlobalHotKeyPreferences {
        guard
            let data = defaults.data(forKey: storageKey),
            let raw = try? JSONDecoder().decode([String: StoredBinding].self, from: data)
        else {
            return GlobalHotKeyPreferences()
        }
        var overrides: [GlobalHotKeyAction: HotKeyBinding?] = [:]
        for (key, stored) in raw {
            guard let action = GlobalHotKeyAction(rawValue: key) else { continue }
            if stored.cleared == true {
                overrides[action] = HotKeyBinding?.none
            } else if let keyCode = stored.keyCode, let modifiers = stored.carbonModifiers {
                overrides[action] = HotKeyBinding(keyCode: keyCode, carbonModifiers: modifiers)
            }
        }
        return GlobalHotKeyPreferences(overrides: overrides)
    }

    func save(defaults: UserDefaults = .standard) {
        var raw: [String: StoredBinding] = [:]
        for (action, binding) in overrides {
            if let binding {
                raw[action.rawValue] = StoredBinding(
                    keyCode: binding.keyCode,
                    carbonModifiers: binding.carbonModifiers
                )
            } else {
                raw[action.rawValue] = StoredBinding(cleared: true)
            }
        }
        if raw.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// 全局快捷键中心：按偏好注册 Carbon 热键，设置页改完调用 `apply` 重注册。
@MainActor
final class GlobalHotKeyCenter {
    static let shared = GlobalHotKeyCenter()

    var onAction: ((GlobalHotKeyAction) -> Void)?
    /// 最近一次 apply 的注册失败（键冲突等），按动作存展示文案。
    private(set) var failureMessages: [GlobalHotKeyAction: String] = [:]

    private var hotKeyRefs: [GlobalHotKeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var handlerInstallFailure: String?

    private init() {}

    func start() {
        installHandlerIfNeeded()
        apply()
    }

    /// 卸掉全部再按偏好注册。返回失败文案（设置页就地展示）。
    @discardableResult
    func apply(preferences: GlobalHotKeyPreferences = .load()) -> [GlobalHotKeyAction: String] {
        installHandlerIfNeeded()
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs = [:]
        failureMessages = [:]

        if let handlerInstallFailure {
            for action in GlobalHotKeyAction.allCases where preferences.binding(for: action) != nil {
                failureMessages[action] = handlerInstallFailure
            }
            report()
            return failureMessages
        }

        for action in GlobalHotKeyAction.allCases {
            guard let binding = preferences.binding(for: action) else { continue }
            let hotKeyID = EventHotKeyID(signature: 0x4C_41_4E_58, id: action.registrationID)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs[action] = ref
            } else {
                failureMessages[action] = String(
                    format: tr("couldn_t_register_shortcut"),
                    binding.displayString,
                    status
                )
            }
        }
        report()
        return failureMessages
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil, handlerInstallFailure == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return noErr }
                // Carbon 把事件投给应用事件目标，回调在主线程。
                MainActor.assumeIsolated {
                    let center = Unmanaged<GlobalHotKeyCenter>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    if let action = GlobalHotKeyAction.action(registrationID: hotKeyID.id) {
                        center.onAction?(action)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
        if status != noErr {
            handlerInstallFailure = String(
                format: tr("couldn_t_install_the_keyboard_handler"),
                status
            )
        }
    }

    private func report() {
        for (action, message) in failureMessages {
            LocalDiagnostics.shared.record(
                operation: "global-hot-key.\(action.rawValue)",
                message: message
            )
        }
    }
}
