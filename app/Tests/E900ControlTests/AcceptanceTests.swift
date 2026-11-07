import XCTest
@testable import E900Control

final class AcceptanceTests: XCTestCase {
    func testOptionParsing() throws {
        let id = UUID()
        let o = try AcceptanceOptions.parse(["--accept", "--id", id.uuidString, "--video-seconds", "8", "--candidates", "--report", "~/r.md", "-NSDocumentRevisionsDebugMode", "YES"])
        XCTAssertEqual(o.deviceID, id); XCTAssertEqual(o.videoSeconds, 8); XCTAssertTrue(o.candidates); XCTAssertEqual(o.report, "~/r.md")
        XCTAssertEqual(try AcceptanceOptions.parse(["--accept"]), AcceptanceOptions())
        XCTAssertThrowsError(try AcceptanceOptions.parse(["--video-seconds", "0"]))
        XCTAssertThrowsError(try AcceptanceOptions.parse(["--video-seconds", "61"]))
        XCTAssertThrowsError(try AcceptanceOptions.parse(["--id", "nope"]))
        XCTAssertThrowsError(try AcceptanceOptions.parse(["--name"]))
        XCTAssertThrowsError(try AcceptanceOptions.parse(["--name", "--list"]))
        XCTAssertThrowsError(try AcceptanceOptions.parse(["--delete-all"]))
    }

    func testDeviceSelectionNeverGuesses() {
        let a = ScannedDevice(id: UUID(), name: "E900-1A2B", rssi: -50)
        let b = ScannedDevice(id: UUID(), name: "e900 pro", rssi: -40)
        let other = ScannedDevice(id: UUID(), name: "QRing R08", rssi: -30)
        XCTAssertEqual(DeviceSelector.choose([a, other], options: .init()), .chosen(a))
        XCTAssertEqual(DeviceSelector.choose([other], options: .init()), DeviceChoice.none)
        XCTAssertEqual(DeviceSelector.choose([a, b, other], options: .init()), .ambiguous([b, a]))
        var byID = AcceptanceOptions(); byID.deviceID = a.id
        XCTAssertEqual(DeviceSelector.choose([a, b], options: byID), .chosen(a))
        byID.deviceID = UUID()
        XCTAssertEqual(DeviceSelector.choose([a, b], options: byID), DeviceChoice.none, "an explicit id never falls back to name matching")
        var byName = AcceptanceOptions(); byName.nameFilter = "R08"
        XCTAssertEqual(DeviceSelector.choose([a, other], options: byName), .chosen(other))
    }

    func testReportVerdictsAndMarkdown() {
        var r = AcceptanceReport(started: Date(timeIntervalSince1970: 0))
        r.device = ScannedDevice(id: UUID(), name: "E900", rssi: -55)
        r.record("電量查詢", .pass, "0x17 回覆 39 37 00")
        r.record("AA15 BLE 預覽", .human, "沒有 | 預覽\n下一行")
        XCTAssertFalse(r.failed); XCTAssertEqual(r.exitCode, 0)
        r.notes.append("確認新照片"); r.log = ["TX 查詢電量"]
        let md = r.markdown(finished: Date(timeIntervalSince1970: 60))
        XCTAssertTrue(md.contains("| 電量查詢 | PASS |"))
        XCTAssertTrue(md.contains("沒有 \\| 預覽 下一行"), "table cells stay on one row")
        XCTAssertTrue(md.contains("- [ ] 確認新照片"))
        XCTAssertTrue(md.contains("TX 查詢電量"))
        r.record("停止錄影", .fail, "未回到 0")
        XCTAssertEqual(r.exitCode, 1)
    }
}
