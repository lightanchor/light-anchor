import Foundation
import XCTest
@testable import LightAnchor

final class PrivacyPermissionTests: XCTestCase {
    func testSceneSourceRulesNormalizeAndMatchSubdomains() {
        let preferences = SceneCapturePreferences(
            applicationRuleMode: .excludeListed,
            applicationBundleIdentifiers: [" COM.EXAMPLE.Secret "],
            websiteRuleMode: .includeOnlyListed,
            websiteHosts: ["https://www.example.com/path"]
        )

        XCTAssertFalse(preferences.allowsApplication("com.example.secret"))
        XCTAssertTrue(preferences.allowsApplication("com.example.editor"))
        XCTAssertTrue(preferences.allowsDocumentURL(URL(string: "https://docs.example.com/guide")))
        XCTAssertFalse(preferences.allowsDocumentURL(URL(string: "https://private.invalid")))
        XCTAssertTrue(preferences.allowsDocumentURL(URL(fileURLWithPath: "/tmp/notes.md")))
    }

    func testSceneCapturePreferencesRoundTrip() {
        let defaults = UserDefaults(suiteName: "LightAnchorPrivacyTests-\(UUID().uuidString)")!
        let preferences = SceneCapturePreferences(
            isAutomaticCapturePaused: true,
            applicationRuleMode: .includeOnlyListed,
            applicationBundleIdentifiers: ["com.example.Editor"],
            websiteHosts: ["Example.com"]
        )

        preferences.save(to: defaults)
        let loaded = SceneCapturePreferences.load(from: defaults)

        XCTAssertTrue(loaded.isAutomaticCapturePaused)
        XCTAssertEqual(loaded.applicationRuleMode, .includeOnlyListed)
        XCTAssertEqual(loaded.applicationBundleIdentifiers, ["com.example.editor"])
        XCTAssertEqual(loaded.websiteHosts, ["example.com"])
    }

    /// 辅助功能和屏幕录制的开关在系统设置里，系统永远不回一个明确的「拒绝」，
    /// 所以这两项不许被判成 denied——回归见 `settleSystemSettingsRequest`。
    func testOnlySystemSettingsCapabilitiesAreMarkedAsSuch() {
        XCTAssertTrue(PrivacyCapability.accessibility.isGrantedInSystemSettings)
        XCTAssertTrue(PrivacyCapability.screenRecording.isGrantedInSystemSettings)
        XCTAssertFalse(PrivacyCapability.microphone.isGrantedInSystemSettings)
        XCTAssertFalse(PrivacyCapability.speechRecognition.isGrantedInSystemSettings)
        XCTAssertFalse(PrivacyCapability.notifications.isGrantedInSystemSettings)

        // 只有屏幕录制的授权结果在进程内被缓存，拨完开关要重开应用。
        XCTAssertEqual(
            PrivacyCapability.allCases.filter(\.requiresRelaunchAfterGrant),
            [.screenRecording]
        )
    }

    /// 问过一次就永久记成「问过」的话，授权按钮会一去不回。授权到手要把标记
    /// 清掉，用户之后在系统设置里关掉才能重新回到「尚未授权」。
    func testGrantedCapabilityForgetsThatItWasEverAsked() {
        let defaults = UserDefaults(suiteName: "LightAnchorPermissionTests-\(UUID().uuidString)")!

        XCTAssertFalse(PrivacyPermissionCache.wasRequested(.accessibility, in: defaults))
        PrivacyPermissionCache.markRequested(.accessibility, in: defaults)
        PrivacyPermissionCache.store(.awaitingSystemSettings, for: .accessibility, in: defaults)
        XCTAssertTrue(PrivacyPermissionCache.wasRequested(.accessibility, in: defaults))
        XCTAssertEqual(
            PrivacyPermissionCache.status(for: .accessibility, in: defaults),
            .awaitingSystemSettings
        )

        PrivacyPermissionCache.clearRequested(.accessibility, in: defaults)
        PrivacyPermissionCache.store(.granted, for: .accessibility, in: defaults)
        XCTAssertFalse(PrivacyPermissionCache.wasRequested(.accessibility, in: defaults))
        XCTAssertEqual(PrivacyPermissionCache.status(for: .accessibility, in: defaults), .granted)
    }

    /// 删除全部本地数据要连「问过没有」一起清干净。
    func testEveryCapabilityContributesBothCacheKeys() {
        XCTAssertEqual(PrivacyPermissionCache.allCacheKeys.count, PrivacyCapability.allCases.count * 2)
        for capability in PrivacyCapability.allCases {
            XCTAssertEqual(
                PrivacyPermissionCache.allCacheKeys.filter { $0.hasSuffix(capability.rawValue) }.count,
                2,
                capability.rawValue
            )
        }
    }

    func testSnapshotCarriesTheWaitingStatusInsteadOfADenial() throws {
        var statuses = Dictionary(
            uniqueKeysWithValues: PrivacyCapability.allCases.map { ($0, PrivacyPermissionStatus.granted) }
        )
        statuses[.accessibility] = .awaitingSystemSettings

        let snapshot = AppPermissionSnapshot.make(statuses: statuses)
        let entry = try XCTUnwrap(
            snapshot.permissions.first { $0.id == PrivacyCapability.accessibility.rawValue }
        )

        XCTAssertEqual(entry.status, "awaitingSystemSettings")
        XCTAssertNotEqual(entry.status, PrivacyPermissionStatus.denied.rawValue)
        XCTAssertEqual(PrivacyPermissionStatus(rawValue: entry.status), .awaitingSystemSettings)
    }

    func testPermissionSnapshotIncludesEveryCapabilityInStableOrder() {
        var statuses = Dictionary(
            uniqueKeysWithValues: PrivacyCapability.allCases.map { ($0, PrivacyPermissionStatus.granted) }
        )
        statuses[.accessibility] = .denied

        let snapshot = AppPermissionSnapshot.make(
            statuses: statuses,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            operatingSystem: "Test OS",
            bundleIdentifier: "com.lightanchor.test",
            appVersion: "1.2.3",
            buildNumber: "45",
            bundlePath: "/Applications/LightAnchor.app",
            executable: "/Applications/LightAnchor.app/Contents/MacOS/LightAnchor"
        )

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.appVersion, "1.2.3")
        XCTAssertEqual(snapshot.buildNumber, "45")
        XCTAssertEqual(snapshot.permissions.map(\.id), PrivacyCapability.allCases.map(\.rawValue))
        XCTAssertEqual(
            snapshot.permissions.first(where: { $0.id == PrivacyCapability.accessibility.rawValue })?.status,
            PrivacyPermissionStatus.denied.rawValue
        )
    }

    func testPermissionReportDestinationRequiresAnAbsolutePath() {
        XCTAssertNil(AppPermissionSnapshotter.reportURL(environment: [:]))
        XCTAssertNil(
            AppPermissionSnapshotter.reportURL(
                environment: [AppPermissionSnapshotter.reportEnvironmentKey: "relative/report.json"]
            )
        )
        XCTAssertEqual(
            AppPermissionSnapshotter.reportURL(
                environment: [AppPermissionSnapshotter.reportEnvironmentKey: "/tmp/report.json"]
            )?.path,
            "/tmp/report.json"
        )
    }

    func testPermissionSnapshotRoundTripsAsISO8601JSON() throws {
        let statuses = Dictionary(
            uniqueKeysWithValues: PrivacyCapability.allCases.map { ($0, PrivacyPermissionStatus.notDetermined) }
        )
        let snapshot = AppPermissionSnapshot.make(
            statuses: statuses,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            operatingSystem: "Test OS",
            bundleIdentifier: "com.lightanchor.test",
            appVersion: "1.2.3",
            buildNumber: "45",
            bundlePath: "/Applications/LightAnchor.app",
            executable: "/Applications/LightAnchor.app/Contents/MacOS/LightAnchor"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(AppPermissionSnapshot.self, from: encoder.encode(snapshot)), snapshot)
    }
}
