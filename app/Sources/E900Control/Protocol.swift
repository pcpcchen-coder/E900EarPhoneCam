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
    /// AA15 file-transfer wrapper used by the reference app for PHOTO_START/TRANS/END:
    /// `52 58 | len BE16 (cmd+payload+crc) | cmd | payload | crc | 58 52`, crc = (cmd + Σpayload) & 0xFF.
    /// Layout taken from the pinned upstream decompiled `FileDatagram.recoverBytesToDatagram` and the
    /// hardware sample `52 58 00 07 97 00 00 2F B8 02 80 58 52` in the E09 reference document.
    static func encodeFile(_ command: UInt8, _ payload: [UInt8] = []) -> Data {
        let n = payload.count + 2
        precondition(n <= 4096)
        let body = [command] + payload
        return Data([0x52, 0x58, UInt8(n >> 8), UInt8(n & 255)] + body + [body.reduce(0, &+), 0x58, 0x52])
    }
}

// Each characteristic owns its own parser; notification boundaries are not frame boundaries.
// AA14 only accepts AC55 frames; AA15 also accepts the 52 58 … 58 52 file wrapper.
struct FrameParser {
    private var buffer: [UInt8] = []
    private(set) var rejected = 0
    private(set) var fileFrames = 0
    var acceptsFileFrames = false
    init(acceptsFileFrames: Bool = false) { self.acceptsFileFrames = acceptsFileFrames }
    mutating func feed(_ data: Data) -> [Frame] {
        buffer += data
        if buffer.count > 64_000 { buffer.removeFirst(buffer.count - 64_000); rejected += 1 }
        var frames: [Frame] = []
        while buffer.count >= 4 {
            let command = buffer[0] == 0xAC && buffer[1] == 0x55
            let file = acceptsFileFrames && buffer[0] == 0x52 && buffer[1] == 0x58
            guard command || file else { buffer.removeFirst(); continue }
            let n = Int(buffer[2]) << 8 | Int(buffer[3])
            guard (2...4096).contains(n) else { rejected += 1; buffer.removeFirst(); continue }
            let total = n + 4 + (file ? 2 : 0)
            guard buffer.count >= total else { break }
            let bytes = Array(buffer.prefix(total))
            if file, bytes[n + 4] != 0x58 || bytes[n + 5] != 0x52 { rejected += 1; buffer.removeFirst(); continue }
            guard bytes[4..<(n + 3)].reduce(UInt8(0), &+) == bytes[n + 3] else {
                rejected += 1; buffer.removeFirst(); continue
            }
            frames.append(Frame(command: bytes[4], payload: Array(bytes[5..<(n + 3)])))
            if file { fileFrames += 1 }
            buffer.removeFirst(total)
        }
        return frames
    }
}

struct PhotoAssembler {
    private var bytes = Data()
    private var covered = Set<Int>()
    private var active = false
    private var chunks = 0
    private var declared: Int?
    /// Human-readable state captured when the last transfer ended (for diagnostics).
    private(set) var lastSummary = ""
    mutating func reset() { bytes = Data(); covered = []; active = false; chunks = 0; declared = nil }
    mutating func accept(_ frame: Frame) -> Data? {
        switch frame.command {
        case 0x97:
            reset(); active = true
            if frame.payload.count >= 4 { declared = frame.payload.prefix(4).reduce(0) { ($0 << 8) | Int($1) } }
        case 0x98:
            guard active, frame.payload.count > 4 else { return nil }
            chunks += 1
            let offset = frame.payload.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let chunk = Array(frame.payload.dropFirst(4))
            guard offset <= 4_000_000, offset + chunk.count <= 4_000_000 else { reset(); return nil }
            let end = offset + chunk.count
            if end > bytes.count { bytes.append(Data(repeating: 0, count: end - bytes.count)) }
            bytes.replaceSubrange(offset..<end, with: chunk)
            covered.formUnion(offset..<end)
        case 0x99:
            lastSummary = "宣告 \(declared.map(String.init) ?? "?") bytes，收到 \(chunks) 塊，涵蓋 \(covered.count)/\(bytes.count) bytes，"
                + "開頭 \(ProtocolValue.hex(bytes.prefix(2)))，結尾 \(ProtocolValue.hex(bytes.suffix(2)))"
            defer { reset() }
            // E900 (fw 1.6.6) pads the last chunk with zero bytes after EOI: 11580 bytes declared and
            // sent, JPEG ends at 11578. Trim a small zero tail; anything else after EOI is rejected.
            var jpeg = bytes
            var trimmed = 0
            while trimmed < 16, jpeg.last == 0 { jpeg.removeLast(); trimmed += 1 }
            guard active, jpeg.count > 4, covered.count == bytes.count,
                  jpeg.prefix(2) == Data([0xFF, 0xD8]), jpeg.suffix(2) == Data([0xFF, 0xD9]) else { return nil }
            return jpeg
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

/// 0x95 GET_SUPPORT_FUNCTION: 4 bytes, big-endian mask (upstream DeviceCapabilityParser).
enum Capability: Int, CaseIterable {
    case live = 0, quickVolume, photoWatermark, wearDetectionDynamic, wearDetection, stabilizationDynamic,
         stabilization, aiWakeWord, offlineVoice, languageSwitch, orientationDynamic, orientation, factoryResetButton
    var title: String {
        switch self {
        case .live: return "即時影像"
        case .quickVolume: return "快捷音量"
        case .photoWatermark: return "照片浮水印"
        case .wearDetectionDynamic: return "佩戴偵測（動態回報）"
        case .wearDetection: return "佩戴偵測"
        case .stabilizationDynamic: return "防手震（動態回報）"
        case .stabilization: return "防手震"
        case .aiWakeWord: return "AI 喚醒詞開關"
        case .offlineVoice: return "本地離線語音"
        case .languageSwitch: return "中英詞條切換"
        case .orientationDynamic: return "橫直向（動態回報）"
        case .orientation: return "橫直向設定"
        case .factoryResetButton: return "獨立恢復原廠按鈕"
        }
    }
    static func mask(_ p: [UInt8]) -> UInt32? {
        guard p.count >= 4 else { return nil }
        return p.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func decode(_ mask: UInt32) -> [Capability] { allCases.filter { mask & (1 << UInt32($0.rawValue)) != 0 } }
}

/// 0x45 ACTION_SYNC flags (byte order confirmed on E09 hardware; E900 confirms bytes 1/2 only).
struct ActionSync: Equatable {
    var photo = false, audio = false, video = false, volumeUp = false, volumeDown = false
    var nod = false, shake = false, music = false, wearing: Bool?, importing: Bool?
    init?(_ p: [UInt8]) {
        guard p.count >= 3 else { return nil }
        func flag(_ i: Int) -> Bool { p.count > i && p[i] == 1 }
        photo = flag(0); audio = flag(1); video = flag(2); volumeUp = flag(3); volumeDown = flag(4)
        nod = flag(5); shake = flag(6); music = flag(7)
        wearing = p.count > 8 ? p[8] == 1 : nil
        importing = p.count > 9 ? p[9] == 1 : nil
    }
}

/// Decodes read-back / push payloads into the value a settings picker would send, per the pinned
/// upstream response beans. `nil` means the payload shape is not understood — keep showing raw hex.
enum Readback {
    static let gestureCodes: [UInt8] = [0x07, 0x08, 0x09, 0x10, 0x11]
    /// Value comparable to the picker's single-byte payload.
    static func pickerValue(code: UInt8, payload p: [UInt8]) -> UInt8? {
        switch code {
        case 0x04, 0x61, 0x01, 0x50, 0x06: return p.count >= 1 ? p[0] : nil
        case _ where gestureCodes.contains(code): return p.count >= 1 ? p[0] : nil
        case 0x72, 0x71: return p.count >= 1 ? p[0] & 3 : nil
        default: return nil
        }
    }
    /// 0x02 reply: CommonValue2Bean (BE16 seconds).
    static func recordSeconds(_ p: [UInt8]) -> Int? { p.count >= 2 ? Int(p[0]) << 8 | Int(p[1]) : nil }
    /// 0x69 reply: system, media, call volume.
    static func volumes(_ p: [UInt8]) -> (system: Int, media: Int, call: Int)? {
        p.count >= 3 ? (Int(p[0]), Int(p[1]), Int(p[2])) : nil
    }
    /// 0x71 reply: inverted bits — 0 means ON.
    static func voiceAssistant(_ p: [UInt8]) -> (offline: Bool, wake: Bool)? {
        guard let b = p.first else { return nil }
        return ((b & 1) == 0, (b & 2) == 0)
    }
    static func voiceAssistantByte(offline: Bool, wake: Bool) -> UInt8 { (offline ? 0 : 1) | (wake ? 0 : 2) }
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

    /// Stop / cancel commands must stay usable once something has started, regardless of the
    /// candidate-feature toggle or a full queue.
    var isStop: Bool {
        switch code {
        case 0x24, 0x56, 0x49, 0x51: return true
        case 0x34: return payload == [0]
        default: return false
        }
    }
    var startsVoiceStream: Bool { code == 0x57 || code == 0x0A }
    var stopsVoiceStream: Bool { code == 0x56 || code == 0x49 }
    /// commandIds that count as the protocol reply to this command on AA14.
    var replyCodes: Set<UInt8> {
        switch code {
        case 0x39, 0x67: return [0x25]
        case 0x40: return [0x40, 0x42]
        case 0x48: return [0x48, 0x02, 0x04, 0x61, 0x07, 0x08, 0x09, 0x10, 0x11]
        default: return [code]
        }
    }
}

enum CommandCatalog {
    // Payloads follow the pinned upstream sender (SendCommandViaBle.configSendCommand appends one
    // parameter byte, even for queries such as 0x55/0x69/0x71/0x95). Only 0x64 is sent payload-less.
    static let all: [DeviceCommand] = [
        .init(id: "battery", group: "裝置資訊", title: "查詢電量", code: 0x17, payload: [0], verified: true),
        .init(id: "capacity", group: "裝置資訊", title: "查詢儲存容量", code: 0x16, payload: [0]),
        .init(id: "info", group: "裝置資訊", title: "查詢韌體版本", code: 0x55, payload: [0]),
        .init(id: "status", group: "裝置資訊", title: "讀取狀態與手勢設定", code: 0x48, payload: [0]),
        .init(id: "capabilities", group: "裝置資訊", title: "讀取硬體能力", code: 0x95, payload: [0]),
        .init(id: "customer", group: "裝置資訊", title: "讀取產品資訊", code: 0x64, payload: []),
        .init(id: "photo", group: "攝影與錄音", title: "拍攝高畫質照片", code: 0x22, payload: [0x31], verified: true),
        .init(id: "thumbnail", group: "攝影與錄音", title: "拍攝縮圖照片", code: 0x22, payload: [0x30]),
        .init(id: "videoStart", group: "攝影與錄音", title: "開始錄影", code: 0x23, payload: [], verified: true),
        .init(id: "videoStop", group: "攝影與錄音", title: "停止錄影", code: 0x24, payload: [], verified: true),
        .init(id: "audioStart", group: "攝影與錄音", title: "開始本機錄音", code: 0x34, payload: [1]),
        .init(id: "audioStop", group: "攝影與錄音", title: "停止本機錄音", code: 0x34, payload: [0]),
        .init(id: "count", group: "攝影與錄音", title: "查詢 BLE 縮圖數量", code: 0x40, payload: [0]),
        .init(id: "prev", group: "音樂與通話", title: "上一首", code: 0x30, payload: [0]),
        .init(id: "next", group: "音樂與通話", title: "下一首", code: 0x30, payload: [1]),
        .init(id: "play", group: "音樂與通話", title: "播放", code: 0x31, payload: [1]),
        .init(id: "pause", group: "音樂與通話", title: "暫停", code: 0x31, payload: [0]),
        // Upstream controlVolume(): 0x32 with VOLUME_DOWN=0 / VOLUME_UP=1. 0x70 is the absolute setter.
        .init(id: "down", group: "音樂與通話", title: "降低音量", code: 0x32, payload: [0]),
        .init(id: "up", group: "音樂與通話", title: "提高音量", code: 0x32, payload: [1]),
        .init(id: "volumes", group: "音樂與通話", title: "查詢三種音量", code: 0x69, payload: [0]),
        .init(id: "answer", group: "音樂與通話", title: "接聽來電", code: 0x33, payload: [1]),
        .init(id: "hangup", group: "音樂與通話", title: "掛斷通話", code: 0x33, payload: [0]),
        .init(id: "pair", group: "音樂與通話", title: "啟動傳統藍牙配對", code: 0x68, payload: [0]),
        .init(id: "wifi", group: "Wi-Fi 與預覽", title: "開啟 Wi-Fi AP", code: 0x39, payload: [0x30]),
        .init(id: "p2p", group: "Wi-Fi 與預覽", title: "開啟 Wi-Fi P2P", code: 0x39, payload: [0x31]),
        .init(id: "live", group: "Wi-Fi 與預覽", title: "啟動即時影像 AP", code: 0x67, payload: [0x30]),
        .init(id: "finish", group: "Wi-Fi 與預覽", title: "結束傳輸並保留原檔", code: 0x44, payload: [0x30, 1]),
        .init(id: "voiceStatus", group: "語音助手", title: "讀取語音助手設定", code: 0x71, payload: [0]),
        .init(id: "voiceStart", group: "語音助手", title: "開始麥克風串流", code: 0x57, payload: [0]),
        .init(id: "voiceStop", group: "語音助手", title: "停止麥克風串流", code: 0x56, payload: [0]),
        .init(id: "voiceCancel", group: "語音助手", title: "取消語音辨識", code: 0x49, payload: [0]),
        .init(id: "replyCancel", group: "語音助手", title: "取消 AI 語音回覆", code: 0x51, payload: [1]),
        .init(id: "photoAI", group: "語音助手", title: "觸發拍照辨識事件", code: 0x0A, payload: []),
        .init(id: "gestureReset", group: "維護", title: "重置手勢設定", code: 0x43, payload: [0], destructive: true),
        .init(id: "historyReset", group: "維護", title: "清除配對紀錄", code: 0x15, payload: [0], destructive: true),
        .init(id: "factoryReset", group: "維護", title: "恢復原廠設定", code: 0x14, payload: [0], destructive: true),
        .init(id: "deleteAll", group: "維護", title: "清空耳機媒體", code: 0x44, payload: [0x30, 0], destructive: true, detail: "此命令可能刪除耳機內全部照片、影片與錄音，無法復原。")
    ]
    static let groups = ["裝置資訊", "攝影與錄音", "音樂與通話", "Wi-Fi 與預覽", "語音助手", "維護"]

    // MARK: parameterised senders (encodings from the pinned upstream SendCommandViaBle)

    static let recordDurations = [60, 180, 300, 420, 600]
    /// 0x02 setRecordDuration: Common2Bean(duration >> 8, duration & 255).
    static func recordDuration(seconds: Int) -> DeviceCommand? {
        guard recordDurations.contains(seconds) else { return nil }
        return .init(id: "recordTime", group: "設定", title: "錄影時長 \(seconds / 60) 分鐘", code: 0x02, payload: [UInt8(seconds >> 8), UInt8(seconds & 255)])
    }
    /// 0x35 setCameraStyle(value1, value2): CAPTURE_STYLE_2K=48 / 1080P=49 and 16_9=48 / 4_3=49.
    /// The upstream app never calls this sender, so which byte is resolution vs aspect is inferred.
    static func captureStyle(is1080p: Bool, is4x3: Bool) -> DeviceCommand {
        .init(id: "captureStyle", group: "設定", title: "畫質 \(is1080p ? "1080P" : "2K") · \(is4x3 ? "4:3" : "16:9")", code: 0x35,
              payload: [is1080p ? 49 : 48, is4x3 ? 49 : 48],
              detail: "原廠 App 有此編碼但未在介面呼叫；兩個位元組的意義由常數名稱推定，E900 待驗證。")
    }
    enum VolumeChannel: UInt8, CaseIterable { case system = 0, media = 1, call = 2
        var title: String { ["系統", "媒體", "通話"][Int(rawValue)] }
        var maximum: Int { self == .media ? 16 : 15 }   // upstream layout: pb_media max 16, others 15
    }
    /// 0x70 setVolume(volumeType, volume).
    static func setVolume(_ channel: VolumeChannel, level: Int) -> DeviceCommand? {
        guard (0...channel.maximum).contains(level) else { return nil }
        return .init(id: "setVolume-\(channel.rawValue)", group: "音樂與通話", title: "設定\(channel.title)音量 \(level)", code: 0x70, payload: [channel.rawValue, UInt8(level)])
    }
    /// 0x72 setVoiceAssistantStatus: bit0 set = offline speech OFF, bit1 set = wake word OFF.
    static func voiceAssistant(offline: Bool, wake: Bool) -> DeviceCommand {
        .init(id: "voiceAssistant", group: "設定", title: "語音助手：離線\(offline ? "開" : "關")／喚醒\(wake ? "開" : "關")", code: 0x72,
              payload: [Readback.voiceAssistantByte(offline: offline, wake: wake)])
    }
    /// 0x59 TIME: year-2000, month, day, hour, minute, second.
    static func clock(_ date: Date, calendar: Calendar = .current) -> DeviceCommand? {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, (2000...2255).contains(year) else { return nil }
        let fields = [year - 2000, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0]
        return .init(id: "clock", group: "設定", title: "同步 Mac 時間", code: 0x59, payload: fields.map { UInt8($0) })
    }
}

/// CoreBluetooth's `CBUUID.uuidString` is not stable across macOS releases: older systems return
/// "AA14" for a 16-bit UUID, macOS 27 returns "0000AA14-0000-1000-8000-00805F9B34FB". Channel
/// routing must compare the short form, or every AA14 reply is silently ignored.
enum BluetoothUUID {
    private static let baseSuffix = "-0000-1000-8000-00805F9B34FB"
    static func short(_ uuid: String) -> String {
        let u = uuid.uppercased()
        guard u.count == 36, u.hasSuffix(baseSuffix) else { return u }
        let head = u.prefix(8)
        return head.hasPrefix("0000") ? String(head.dropFirst(4)) : String(head)
    }
}
