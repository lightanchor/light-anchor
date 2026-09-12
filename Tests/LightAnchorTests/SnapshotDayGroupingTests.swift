import XCTest
@testable import LightAnchor

final class SnapshotDayGroupingTests: XCTestCase {
    /// 钉在日历日上造数据：以今天 0 点为锚加减小时，任何时刻跑都不会跨日漂移。
    private func snapshot(_ hoursFromStartOfToday: Double, _ subject: String) -> LightAnchorSnapshot {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return LightAnchorSnapshot(
            id: subject,
            date: startOfToday.addingTimeInterval(hoursFromStartOfToday * 3600),
            subject: subject
        )
    }

    func testGroupsTodayYesterdayAndOlderSeparately() {
        let snapshots = [
            snapshot(5, "b-today-late"),
            snapshot(2, "a-today-early"),
            snapshot(-4, "c-yesterday"),
            snapshot(-80, "d-older"),
        ]
        let groups = SnapshotDayGrouping.groups(for: snapshots)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].label, tr("today"))
        XCTAssertEqual(groups[1].label, tr("yesterday"))
        XCTAssertEqual(groups[0].snapshots.map(\.subject), ["b-today-late", "a-today-early"])
        XCTAssertEqual(groups[1].snapshots.map(\.subject), ["c-yesterday"])
        XCTAssertEqual(groups[2].snapshots.map(\.subject), ["d-older"])
    }

    func testOlderDayLabelCarriesDateAndWeekday() {
        let label = SnapshotDayGrouping.label(for: snapshot(-80, "x").date)
        // 不是「今天/昨天」时给具体日期（zh: 9月8日 周二；en: Sep 8 Tue）。
        XCTAssertFalse(label == tr("today") || label == tr("yesterday"))
        XCTAssertFalse(label.isEmpty)
    }

    func testPreservesInputOrderWithinADay() {
        // 输入必须已按新→旧排好（history 的输出）；分组不得重排。
        let snapshots = [snapshot(8, "new"), snapshot(5, "mid"), snapshot(2, "old")]
        let groups = SnapshotDayGrouping.groups(for: snapshots)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].snapshots.map(\.subject), ["new", "mid", "old"])
    }
}
