import Carbon.HIToolbox
import XCTest
@testable import LightAnchor

/// 全局快捷键偏好：缺项 = 默认值，改键 = 覆盖，清除 = 不注册，
/// 三种状态都要经得起存取往返。
final class GlobalHotKeyPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "GlobalHotKeyPreferencesTests")
        defaults.removePersistentDomain(forName: "GlobalHotKeyPreferencesTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "GlobalHotKeyPreferencesTests")
        super.tearDown()
    }

    func testDefaultsWhenNothingStored() {
        let preferences = GlobalHotKeyPreferences.load(defaults: defaults)
        XCTAssertEqual(
            preferences.binding(for: .capture),
            HotKeyBinding(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(optionKey | cmdKey))
        )
        XCTAssertNil(preferences.binding(for: .openMainWindow))
    }

    func testOverrideSurvivesRoundTrip() {
        var preferences = GlobalHotKeyPreferences.load(defaults: defaults)
        let custom = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_J),
            carbonModifiers: UInt32(controlKey | cmdKey)
        )
        preferences.setBinding(custom, for: .capture)
        preferences.save(defaults: defaults)

        let reloaded = GlobalHotKeyPreferences.load(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .capture), custom)
    }

    func testClearedBindingStaysClearedAfterRoundTrip() {
        var preferences = GlobalHotKeyPreferences.load(defaults: defaults)
        preferences.setBinding(nil, for: .capture)
        preferences.save(defaults: defaults)

        let reloaded = GlobalHotKeyPreferences.load(defaults: defaults)
        XCTAssertNil(reloaded.binding(for: .capture))
    }

    func testResetToDefaultRemovesOverride() {
        var preferences = GlobalHotKeyPreferences.load(defaults: defaults)
        preferences.setBinding(nil, for: .capture)
        preferences.resetToDefault(for: .capture)
        preferences.save(defaults: defaults)

        let reloaded = GlobalHotKeyPreferences.load(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .capture), GlobalHotKeyAction.capture.defaultBinding)
    }

    func testBindingRequiresCommandingModifier() {
        let shiftOnly = HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(shiftKey))
        XCTAssertFalse(shiftOnly.hasCommandingModifier)
        let withOption = HotKeyBinding(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey))
        XCTAssertTrue(withOption.hasCommandingModifier)
    }

    func testDisplayStringOrder() {
        let binding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_N),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        XCTAssertEqual(binding.displayString, "⌃ ⌥ ⇧ ⌘ N")
    }
}
