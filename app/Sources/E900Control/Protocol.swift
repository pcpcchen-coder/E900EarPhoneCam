import Foundation

struct Frame: Equatable {
    let command: UInt8
    let payload: [UInt8]
    static func encode(_ command: UInt8, _ payload: [UInt8] = [], incoming: Bool = false) -> Data {
        let n = payload.count + 2
        precondition(n <= 4096)
        let body = [command] + payload
        return Data([incoming ? 0xAC : 0xAB, 0x55, UInt8(n >> 8), UInt8(n & 255)] + body + [body.reduce(0, &+)])
    }
}

// Each characteristic owns its own parser; notification boundaries are not frame boundaries.
struct FrameParser {
    private var buffer: [UInt8] = []
    private(set) var rejected = 0
    mutating func feed(_ data: Data) -> [Frame] {
        buffer += data
        var frames: [Frame] = []
        while buffer.count >= 4 {
            guard buffer[0] == 0xAC, buffer[1] == 0x55 else { buffer.removeFirst(); continue }
            let n = Int(buffer[2]) << 8 | Int(buffer[3])
            guard (2...4096).contains(n) else { rejected += 1; buffer.removeFirst(); continue }
            guard buffer.count >= n + 4 else { break }
            let bytes = Array(buffer.prefix(n + 4))
            guard bytes[4..<(n + 3)].reduce(UInt8(0), &+) == bytes[n + 3] else {
                rejected += 1; buffer.removeFirst(); continue
            }
            frames.append(Frame(command: bytes[4], payload: Array(bytes[5..<(n + 3)])))
            buffer.removeFirst(n + 4)
        }
        return frames
    }
}

struct PhotoAssembler {
    private var bytes = Data()
    private var covered = Set<Int>()
    private var active = false
    mutating func reset() { bytes = Data(); covered = []; active = false }
    mutating func accept(_ frame: Frame) -> Data? {
        switch frame.command {
        case 0x97: reset(); active = true
        case 0x98:
            guard active, frame.payload.count > 4 else { return nil }
            let offset = frame.payload.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let chunk = Array(frame.payload.dropFirst(4))
            guard offset <= 4_000_000, offset + chunk.count <= 4_000_000 else { reset(); return nil }
            let end = offset + chunk.count
            if end > bytes.count { bytes.append(Data(repeating: 0, count: end - bytes.count)) }
            bytes.replaceSubrange(offset..<end, with: chunk)
            covered.formUnion(offset..<end)
        case 0x99:
            defer { reset() }
            guard active, bytes.count > 4, covered.count == bytes.count,
                  bytes.prefix(2) == Data([0xFF, 0xD8]), bytes.suffix(2) == Data([0xFF, 0xD9]) else { return nil }
            return bytes
        default: break
        }
        return nil
    }
}

enum ProtocolValue {
    static func battery(_ p: [UInt8]) -> Int? {
        guard p.count >= 3 else { return nil }
        let a = Int(p[0] & 15), b = Int(p[1] & 15)
        guard a <= 9, b <= 9, a * 10 + b <= 100 else { return nil }
        return a * 10 + b
    }
    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    static func parseHex(_ text: String) -> [UInt8]? {
        let cleaned = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        guard cleaned.count % 2 == 0, cleaned.count <= 8000 else { return nil }
        var out: [UInt8] = []; var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let end = cleaned.index(i, offsetBy: 2)
            guard let b = UInt8(cleaned[i..<end], radix: 16) else { return nil }
            out.append(b); i = end
        }
        return out
    }
}

struct DeviceCommand: Identifiable, Hashable {
    let id: String
    let group: String
    let title: String
    let code: UInt8
    let payload: [UInt8]
    var verified = false
    var destructive = false
    var detail = "E09 參考協定；E900 待實機驗證。"
}

enum CommandCatalog {
    static let all: [DeviceCommand] = [
        .init(id: "battery", group: "裝置資訊", title: "查詢電量", code: 0x17, payload: [0], verified: true),
        .init(id: "capacity", group: "裝置資訊", title: "查詢儲存容量", code: 0x16, payload: [0]),
        .init(id: "info", group: "裝置資訊", title: "查詢韌體版本", code: 0x55, payload: []),
        .init(id: "status", group: "裝置資訊", title: "讀取狀態與手勢設定", code: 0x48, payload: [0]),
        .init(id: "capabilities", group: "裝置資訊", title: "讀取硬體能力", code: 0x95, payload: []),
        .init(id: "customer", group: "裝置資訊", title: "讀取產品資訊", code: 0x64, payload: []),
        .init(id: "photo", group: "攝影與錄音", title: "拍攝高畫質照片", code: 0x22, payload: [0x31], verified: true),
        .init(id: "thumbnail", group: "攝影與錄音", title: "拍攝縮圖照片", code: 0x22, payload: [0x30]),
        .init(id: "videoStart", group: "攝影與錄音", title: "開始錄影", code: 0x23, payload: [], verified: true),
        .init(id: "videoStop", group: "攝影與錄音", title: "停止錄影", code: 0x24, payload: [], verified: true),
        .init(id: "audioStart", group: "攝影與錄音", title: "開始本機錄音", code: 0x34, payload: [1]),
        .init(id: "audioStop", group: "攝影與錄音", title: "停止本機錄音", code: 0x34, payload: [0]),
        .init(id: "count", group: "攝影與錄音", title: "查詢 BLE 縮圖數量", code: 0x40, payload: []),
        .init(id: "prev", group: "音樂與通話", title: "上一首", code: 0x30, payload: [0]),
        .init(id: "next", group: "音樂與通話", title: "下一首", code: 0x30, payload: [1]),
        .init(id: "play", group: "音樂與通話", title: "播放", code: 0x31, payload: [1]),
        .init(id: "pause", group: "音樂與通話", title: "暫停", code: 0x31, payload: [0]),
        .init(id: "down", group: "音樂與通話", title: "降低音量", code: 0x70, payload: [0]),
        .init(id: "up", group: "音樂與通話", title: "提高音量", code: 0x70, payload: [1]),
        .init(id: "volumes", group: "音樂與通話", title: "查詢三種音量", code: 0x69, payload: []),
        .init(id: "answer", group: "音樂與通話", title: "接聽來電", code: 0x33, payload: [1]),
        .init(id: "hangup", group: "音樂與通話", title: "掛斷通話", code: 0x33, payload: [0]),
        .init(id: "pair", group: "音樂與通話", title: "啟動傳統藍牙配對", code: 0x68, payload: []),
        .init(id: "wifi", group: "Wi-Fi 與預覽", title: "開啟 Wi-Fi AP", code: 0x39, payload: [0x30]),
        .init(id: "p2p", group: "Wi-Fi 與預覽", title: "開啟 Wi-Fi P2P", code: 0x39, payload: [0x31]),
        .init(id: "live", group: "Wi-Fi 與預覽", title: "啟動即時影像 AP", code: 0x67, payload: [0x30]),
        .init(id: "finish", group: "Wi-Fi 與預覽", title: "結束傳輸並保留原檔", code: 0x44, payload: [0x30, 1]),
        .init(id: "voiceStatus", group: "語音助手", title: "讀取語音助手設定", code: 0x71, payload: []),
        .init(id: "voiceStart", group: "語音助手", title: "開始麥克風串流", code: 0x57, payload: [0]),
        .init(id: "voiceStop", group: "語音助手", title: "停止麥克風串流", code: 0x56, payload: [0]),
        .init(id: "voiceCancel", group: "語音助手", title: "取消語音辨識", code: 0x49, payload: [0]),
        .init(id: "replyCancel", group: "語音助手", title: "取消 AI 語音回覆", code: 0x51, payload: [1]),
        .init(id: "photoAI", group: "語音助手", title: "觸發拍照辨識事件", code: 0x0A, payload: []),
        .init(id: "gestureReset", group: "維護", title: "重置手勢設定", code: 0x43, payload: [], destructive: true),
        .init(id: "historyReset", group: "維護", title: "清除配對紀錄", code: 0x15, payload: [0], destructive: true),
        .init(id: "factoryReset", group: "維護", title: "恢復原廠設定", code: 0x14, payload: [0], destructive: true),
        .init(id: "deleteAll", group: "維護", title: "清空耳機媒體", code: 0x44, payload: [0x30, 0], destructive: true, detail: "此命令可能刪除耳機內全部照片、影片與錄音，無法復原。")
    ]
    static let groups = ["裝置資訊", "攝影與錄音", "音樂與通話", "Wi-Fi 與預覽", "語音助手", "維護"]
}
