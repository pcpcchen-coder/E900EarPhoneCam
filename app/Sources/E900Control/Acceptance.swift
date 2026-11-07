import AppKit
import CoreBluetooth
import Foundation

/// Headless hardware acceptance: `E900Control --accept`. Drives the same `Headset` the UI uses,
/// sends only the E900-verified commands (battery, photo, video start/stop) plus optional
/// read-only E09 queries, and never sends settings, delete, reset or OTA.
@MainActor final class AcceptanceRunner {
    private let options: AcceptanceOptions
    private let headset = Headset()
    private var report = AcceptanceReport()

    init(options: AcceptanceOptions) { self.options = options }

    func run() async -> Int32 {
        defer { if headset.ready || headset.connecting { headset.disconnect() } }
        say("E900 自動驗收開始；不會送出設定、刪除、重置或 OTA 指令。")
        say("等待藍牙（最多 60 秒；重新建置後 macOS 可能再次詢問藍牙權限，請按允許）…")

        guard await waitUntil(60, { self.headset.status.hasPrefix("藍牙已開啟") }) else {
            say("藍牙不可用：\(headset.status)")
            say("請用 scripts/install-and-accept.sh（以 open 啟動 .app），並在「系統設定 → 隱私權與安全性 → 藍牙」允許 E900 Control 後重試。")
            report.record("藍牙", .fail, headset.status)
            return finish()
        }

        headset.scan()
        say("掃描附近裝置 12 秒…")
        _ = await waitUntil(13, { !self.headset.scanning })
        let scanned = headset.devices.map { ScannedDevice(id: $0.id, name: $0.name, rssi: $0.rssi, services: $0.services) }
        if options.listOnly {
            for d in scanned.sorted(by: { $0.rssi > $1.rssi }) {
                let svc = d.services.isEmpty ? "" : "  [\(d.services.joined(separator: ","))]"
                let mark = d.advertisesCommandService ? "  ← AA12" : ""
                say("\(d.rssi) dBm  \(d.name)  \(d.id.uuidString)\(svc)\(mark)")
            }
            return 0
        }
        let target: ScannedDevice
        switch DeviceSelector.choose(scanned, options: options) {
        case let .chosen(d): target = d
        case .none:
            report.record("找到裝置", .fail, "沒有名稱含「\(options.nameFilter)」\(options.deviceID.map { "或 ID \($0)" } ?? "")的裝置；請確認耳機開機、GlassX 未佔用連線。可用 --list 查看。")
            return finish()
        case let .ambiguous(list):
            report.record("找到裝置", .fail, "多台符合，請用 --id 指定：" + list.map { "\($0.name) \($0.id.uuidString)" }.joined(separator: "；"))
            return finish()
        }
        report.device = target
        report.record("找到裝置", .pass, "\(target.name) \(target.rssi) dBm")

        // Connect + AA14/AA15 subscription; Headset auto-queries battery once ready.
        headset.selected = target.id
        headset.connect()
        guard await waitUntil(26, { self.headset.ready }) else {
            report.record("連線與訂閱", .fail, headset.status)
            return finish()
        }
        report.record("連線與訂閱", .pass, "AA13 write、AA14/AA15 notify 就緒")

        if await waitUntil(6, { self.headset.values[0x17] != nil }) {
            report.record("電量查詢", .pass, "0x17 回覆 \(ProtocolValue.hex(headset.values[0x17]!))；\(headset.battery)")
        } else { report.record("電量查詢", .fail, "6 秒內沒有 0x17 回覆") }

        await photo()
        await video()
        if options.candidates { await candidates() }

        // Disconnect must clear state and must not replay anything on reconnect.
        headset.disconnect()
        let cleared = await waitUntil(3, { !self.headset.ready && self.headset.pendingCommands == 0 && self.headset.values.isEmpty })
        report.record("中斷與狀態重置", cleared ? .pass : .fail, cleared ? "ready=false，佇列與狀態清空" : "中斷後狀態未清空")
        return finish()
    }

    private func photo() async {
        headset.values[0x22] = nil
        let previewBefore = headset.lastPreviewJPEG
        headset.run(command("photo"))
        if await waitUntil(6, { self.headset.values[0x22] != nil }) {
            report.record("拍照指令", .pass, "0x22 回覆 \(ProtocolValue.hex(headset.values[0x22]!))")
            report.notes.append("拍照時間附近，耳機（GlassX 或 Wi-Fi 清單）出現一張新照片")
        } else {
            report.record("拍照指令", .fail, "6 秒內沒有 0x22 回覆：\(headset.latestResult)")
        }
        if await waitUntil(15, { self.headset.lastPreviewJPEG != nil && self.headset.lastPreviewJPEG != previewBefore }), let jpeg = headset.lastPreviewJPEG {
            let url = reportURL().deletingPathExtension().appendingPathExtension("preview.jpg")
            try? jpeg.write(to: url)
            report.record("AA15 BLE 預覽", .pass, "完整 JPEG \(jpeg.count) bytes，已存 \(url.lastPathComponent)（低解析）")
            report.notes.append("打開 \(url.lastPathComponent)，確認是剛拍的畫面")
        } else {
            report.record("AA15 BLE 預覽", .human, "15 秒內沒有完整 JPEG；E900 拍照後未必推送預覽，不列為失敗")
            if !headset.rawAA15.isEmpty {
                let raw = reportURL().deletingPathExtension().appendingPathExtension("aa15.bin")
                try? headset.rawAA15.write(to: raw)
                report.notes.append("AA15 原始位元組已存 \(raw.lastPathComponent)（\(headset.rawAA15.count) bytes），供分析預覽格式")
            }
        }
    }

    private func video() async {
        headset.values[0x23] = nil; headset.values[0x24] = nil
        headset.run(command("videoStart"))
        let ack = await waitUntil(6, { self.headset.values[0x23] != nil })
        let flag = await waitUntil(6, { self.headset.recording == "錄影中" })
        report.record("開始錄影", ack && flag ? .pass : .fail,
                      "0x23 回覆：\(ack ? "有" : "無")；ACTION_SYNC 錄影旗標：\(flag ? "1" : "未觀察到")")
        // Always stop, even if the start looked unsuccessful.
        try? await Task.sleep(nanoseconds: UInt64(options.videoSeconds) * 1_000_000_000)
        headset.run(command("videoStop"))
        let stopAck = await waitUntil(6, { self.headset.values[0x24] != nil })
        let stopped = await waitUntil(6, { self.headset.recording == "未錄影" })
        report.record("停止錄影", stopAck && stopped ? .pass : .fail,
                      "0x24 回覆：\(stopAck ? "有" : "無")；ACTION_SYNC 錄影旗標：\(stopped ? "0" : "未回到 0")")
        if !stopped { report.notes.append("耳機可能仍在錄影：請手動按耳機鍵或在 App 按停止錄影") }
        report.notes.append("耳機有一段約 \(options.videoSeconds) 秒、可播放的新影片")
    }

    private func candidates() async {
        headset.experimental = true
        defer { headset.experimental = false }
        for id in ["info", "capacity", "capabilities", "status", "voiceStatus", "volumes"] {
            let c = command(id)
            for code in c.replyCodes { headset.values[code] = nil }
            headset.run(c)
            let got = await waitUntil(6, { c.replyCodes.contains { self.headset.values[$0] != nil } })
            let code = c.replyCodes.first { headset.values[$0] != nil }
            report.record("候選：\(c.title)", got ? .pass : .human,
                          got ? "\(String(format: "%02X", code!)) 回覆 \(ProtocolValue.hex(headset.values[code!]!))" : "6 秒內無回覆（E09 候選，E900 可能不支援）")
        }
        if let caps = headset.capabilities { report.notes.append("核對能力位元：" + Capability.decode(caps).map(\.title).joined(separator: "、")) }
    }

    // MARK: helpers

    private func command(_ id: String) -> DeviceCommand { CommandCatalog.all.first { $0.id == id }! }
    private func waitUntil(_ seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
    private func say(_ text: String) { print(text); fflush(stdout) }
    private lazy var reportPath: URL = {
        if let path = self.options.report { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("acceptance-reports").appendingPathComponent("E900-\(f.string(from: self.report.started)).md")
    }()
    private func reportURL() -> URL {
        try? FileManager.default.createDirectory(at: reportPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        return reportPath
    }
    private func finish() -> Int32 {
        report.log = headset.logs
        let text = report.markdown()
        let url = reportURL()
        do { try text.write(to: url, atomically: true, encoding: .utf8); say("報告：\(url.path)") }
        catch { say("報告寫入失敗：\(error.localizedDescription)") }
        for g in report.gates { say("[\(g.verdict.rawValue)] \(g.name)：\(g.detail)") }
        for n in report.notes { say("待人工確認：\(n)") }
        return report.exitCode
    }
}
