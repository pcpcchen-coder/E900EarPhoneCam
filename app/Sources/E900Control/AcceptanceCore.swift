import Foundation

/// UI-free pieces of the headless acceptance run (`E900Control --accept`): argument parsing,
/// target-device selection and the report. Kept pure so they are unit-tested on any platform.
struct AcceptanceOptions: Equatable {
    var nameFilter = "E900"
    var deviceID: UUID?
    var videoSeconds = 5
    var candidates = false
    var report: String?
    var listOnly = false

    static let usage = """
    E900Control --accept [選項]
      --name <文字>        依廣播名稱挑選（預設 E900，不分大小寫）
      --id <UUID>          指定 CoreBluetooth 裝置 UUID（多台符合時必填）
      --video-seconds <n>  錄影長度，1–60 秒（預設 5）
      --candidates         另跑唯讀的 E09 候選查詢（版本、容量、能力、狀態、語音、音量）
      --report <路徑>      報告輸出位置（預設 ./acceptance-reports/E900-<時間>.md）
      --list               只掃描並列出附近裝置
    不會執行設定變更、刪除、重置或 OTA。
    """

    static func parse(_ args: [String]) throws -> AcceptanceOptions {
        var o = AcceptanceOptions()
        var i = 0
        func value() throws -> String {
            i += 1
            guard i < args.count, !args[i].hasPrefix("--") else { throw OptionError.missingValue(args[i - 1]) }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--accept": break
            case "--name": o.nameFilter = try value()
            case "--id":
                let text = try value()
                guard let id = UUID(uuidString: text) else { throw OptionError.invalid("--id", text) }
                o.deviceID = id
            case "--video-seconds":
                let text = try value()
                guard let n = Int(text), (1...60).contains(n) else { throw OptionError.invalid("--video-seconds", text) }
                o.videoSeconds = n
            case "--candidates": o.candidates = true
            case "--report": o.report = try value()
            case "--list": o.listOnly = true
            default:
                // macOS may append -NSDocumentRevisionsDebugMode / -psn_ when launched by Xcode or Finder.
                if args[i].hasPrefix("-psn_") { i += 1; continue }
                if args[i].hasPrefix("-NS") { i += 2; continue }   // -NSKey value
                throw OptionError.unknown(args[i])
            }
            i += 1
        }
        return o
    }

    enum OptionError: LocalizedError, Equatable {
        case missingValue(String), invalid(String, String), unknown(String)
        var errorDescription: String? {
            switch self {
            case let .missingValue(f): return "\(f) 需要參數"
            case let .invalid(f, v): return "\(f) 的值無效：\(v)"
            case let .unknown(f): return "未知參數：\(f)"
            }
        }
    }
}

struct ScannedDevice: Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

enum DeviceChoice: Equatable {
    case chosen(ScannedDevice)
    case none
    case ambiguous([ScannedDevice])
}

enum DeviceSelector {
    /// Never guesses between several matching headsets: an explicit `--id` wins, otherwise exactly
    /// one device whose advertised name contains the filter must be present.
    static func choose(_ devices: [ScannedDevice], options: AcceptanceOptions) -> DeviceChoice {
        if let id = options.deviceID {
            return devices.first { $0.id == id }.map(DeviceChoice.chosen) ?? .none
        }
        let matches = devices.filter { $0.name.range(of: options.nameFilter, options: .caseInsensitive) != nil }
        switch matches.count {
        case 0: return .none
        case 1: return .chosen(matches[0])
        default: return .ambiguous(matches.sorted { $0.rssi > $1.rssi })
        }
    }
}

struct AcceptanceReport {
    enum Verdict: String { case pass = "PASS", fail = "FAIL", human = "待人工確認", skipped = "SKIP" }
    struct Gate { let name: String; let verdict: Verdict; let detail: String }

    var started = Date()
    var device: ScannedDevice?
    var gates: [Gate] = []
    var notes: [String] = []
    var log: [String] = []

    mutating func record(_ name: String, _ verdict: Verdict, _ detail: String) { gates.append(.init(name: name, verdict: verdict, detail: detail)) }
    var failed: Bool { gates.contains { $0.verdict == .fail } }
    var exitCode: Int32 { failed ? 1 : 0 }

    func markdown(finished: Date = Date()) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        var s = "# E900 Control 自動驗收報告\n\n"
        s += "- 開始：\(f.string(from: started))\n- 結束：\(f.string(from: finished))\n"
        if let d = device { s += "- 裝置：\(d.name)（\(d.id.uuidString)，\(d.rssi) dBm）\n" }
        s += "- 結果：\(failed ? "有項目失敗" : "自動項目未失敗")；PASS 只代表協定／狀態層面，照片與影片內容需人工確認。\n\n"
        s += "| 項目 | 結果 | 說明 |\n|---|---|---|\n"
        for g in gates { s += "| \(g.name) | \(g.verdict.rawValue) | \(g.detail.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")) |\n" }
        if !notes.isEmpty { s += "\n## 需要人工確認\n\n" + notes.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n" }
        if !log.isEmpty { s += "\n## 協定記錄\n\n```text\n" + log.joined(separator: "\n") + "\n```\n" }
        return s
    }
}
