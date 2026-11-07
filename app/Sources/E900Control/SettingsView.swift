import SwiftUI

/// Picker value is what will be sent. When the headset reports a value for the same commandId
/// (0x48 read-back pushes gestures/wear/direction on their own IDs), the picker follows it and the
/// row shows "耳機回報"; otherwise it stays a not-yet-confirmed choice.
struct SettingPicker: View {
    @EnvironmentObject var headset: Headset
    let title: String; let code: UInt8; let choices: [(String, UInt8)]
    let submit: (DeviceCommand) -> Void
    @State private var value = 0
    var body: some View {
        HStack {
            Picker(title, selection: $value) { ForEach(choices.indices, id: \.self) { i in Text(choices[i].0).tag(i) } }
            Button("套用") { submit(.init(id: "setting-\(code)", group: "設定", title: "\(title)：\(choices[value].0)", code: code, payload: [choices[value].1])) }
            readback
        }
        .disabled(!headset.ready || !headset.experimental)
        .onAppear(perform: follow)
        .onChange(of: headset.values[code]) { _ in follow() }
    }
    private var reported: UInt8? { headset.values[code].flatMap { Readback.pickerValue(code: code, payload: $0) } }
    @ViewBuilder private var readback: some View {
        if let v = reported, let i = choices.firstIndex(where: { $0.1 == v }) {
            Text("耳機回報：\(choices[i].0)").font(.caption).foregroundStyle(.green)
        } else if let p = headset.values[code] {
            Text("回覆 \(ProtocolValue.hex(p))（無法對應選項）").font(.caption.monospaced()).foregroundStyle(.orange)
        } else {
            Text("未讀回").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func follow() {
        if let v = reported, let i = choices.firstIndex(where: { $0.1 == v }) { value = i }
    }
}

struct SettingsView: View {
    @EnvironmentObject var headset: Headset
    let submit: (DeviceCommand) -> Void
    @State private var duration = 180
    @State private var is1080p = false
    @State private var is4x3 = false
    @State private var offline = true
    @State private var wake = true
    @State private var levels: [UInt8: Double] = [0: 8, 1: 8, 2: 8]
    private var enabled: Bool { headset.ready && headset.experimental }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("開啟 E09 候選功能", isOn: $headset.experimental)
            Text("選單是準備送出的值。耳機回報同一指令的值時（例如「讀回狀態」會逐項推送手勢、佩戴、方向、錄影時長），選單會跟著改為耳機回報值並標示綠色；其餘仍屬未確認。協定回覆不等於設定已生效，需實機效果確認。").foregroundStyle(.secondary)
            HStack {
                Button("讀回狀態與手勢") { send("status") }
                Button("讀回語音助手") { send("voiceStatus") }
                Button("讀回音量") { send("volumes") }
            }.disabled(!enabled)
            GroupBox("攝影與裝置") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingPicker(title: "亮度", code: 0x01, choices: [("低", 48), ("中", 49), ("高", 50)], submit: submit)
                    SettingPicker(title: "佩戴偵測", code: 0x04, choices: [("關閉", 48), ("開啟", 49)], submit: submit)
                    SettingPicker(title: "攝影模式", code: 0x50, choices: [("標準", 48), ("經典", 49)], submit: submit)
                    SettingPicker(title: "鏡頭方向", code: 0x61, choices: [("直向", 48), ("橫向", 49)], submit: submit)
                    HStack {
                        Picker("錄影時長", selection: $duration) { ForEach(CommandCatalog.recordDurations, id: \.self) { Text("\($0 / 60) 分鐘").tag($0) } }
                        Button("套用") { if let c = CommandCatalog.recordDuration(seconds: duration) { submit(c) } }
                        if let p = headset.values[0x02], let s = Readback.recordSeconds(p) { Text("耳機回報：\(s) 秒").font(.caption).foregroundStyle(.green) }
                        else { Text("未讀回").font(.caption).foregroundStyle(.secondary) }
                    }.disabled(!enabled)
                    HStack {
                        Picker("解析度", selection: $is1080p) { Text("2K").tag(false); Text("1080P").tag(true) }.frame(width: 200)
                        Picker("比例", selection: $is4x3) { Text("16:9").tag(false); Text("4:3").tag(true) }.frame(width: 180)
                        Button("套用畫質") { submit(CommandCatalog.captureStyle(is1080p: is1080p, is4x3: is4x3)) }
                    }.disabled(!enabled)
                    Text("錄影時長 0x02 依原廠編碼（秒數，2 bytes big-endian）。畫質 0x35 原廠 App 有編碼但未呼叫，位元組順序依常數推定。麥克風 0x03 原廠無呼叫、值域不明，只保留在進階頁。").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("耳機時間"); Spacer(); Button("同步 Mac 時間") { headset.syncClock() }.disabled(!enabled) }
                }.padding(14)
            }
            GroupBox("手勢配置") {
                VStack(spacing: 16) {
                    ForEach(Array(zip(["向前滑", "向後滑", "單擊", "雙擊", "三擊"], Readback.gestureCodes)), id: \.1) { title, code in
                        SettingPicker(title: title, code: code, choices: [("音量減", 48), ("音量增", 49), ("播放／暫停／接聽／掛斷", 50), ("上一首", 51), ("下一首", 52)], submit: submit)
                    }
                }.padding(14)
            }
            GroupBox("音量（0x70 絕對值）") {
                VStack(alignment: .leading, spacing: 12) {
                    if let p = headset.values[0x69], let v = Readback.volumes(p) { Text("耳機回報：系統 \(v.system) · 媒體 \(v.media) · 通話 \(v.call)").font(.caption).foregroundStyle(.green) }
                    ForEach(CommandCatalog.VolumeChannel.allCases, id: \.rawValue) { channel in
                        HStack {
                            Text(channel.title).frame(width: 40, alignment: .leading)
                            Slider(value: Binding(get: { levels[channel.rawValue] ?? 0 }, set: { levels[channel.rawValue] = $0.rounded() }), in: 0...Double(channel.maximum), step: 1)
                            Text("\(Int(levels[channel.rawValue] ?? 0))/\(channel.maximum)").font(.caption.monospaced()).frame(width: 50)
                            Button("套用") { if let c = CommandCatalog.setVolume(channel, level: Int(levels[channel.rawValue] ?? 0)) { submit(c) } }
                        }
                    }
                    Text("範圍取自原廠快捷音量頁（媒體 0–16，系統／通話 0–15）。").font(.caption).foregroundStyle(.secondary)
                }.padding(14).disabled(!enabled)
            }
            GroupBox("離線語音與喚醒詞") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingPicker(title: "手動語音指令", code: 0x06, choices: [("關閉", 48), ("開啟", 49)], submit: submit)
                    SettingPicker(title: "離線語言", code: 0x62, choices: [("中文", 0), ("英文", 1)], submit: submit)
                    HStack {
                        Toggle("本地離線語音", isOn: $offline)
                        Toggle("AI 喚醒詞", isOn: $wake)
                        Button("套用") { submit(CommandCatalog.voiceAssistant(offline: offline, wake: wake)) }
                        if let p = headset.values[0x71], let v = Readback.voiceAssistant(p) { Text("耳機回報：離線\(v.offline ? "開" : "關")／喚醒\(v.wake ? "開" : "關")").font(.caption).foregroundStyle(.green) }
                    }.disabled(!enabled)
                    Text("0x72／0x71 為反向位元（0 = 開），已由 App 轉換。能力位元與開關編碼源自 E09；E900 需驗證。缺乏喚醒詞能力時，設定不會新增硬體功能。").font(.caption).foregroundStyle(.secondary)
                }.padding(14)
            }
        }
        .onChange(of: headset.values[0x71]) { p in if let p, let v = Readback.voiceAssistant(p) { offline = v.offline; wake = v.wake } }
        .onChange(of: headset.values[0x02]) { p in if let p, let s = Readback.recordSeconds(p), CommandCatalog.recordDurations.contains(s) { duration = s } }
        .onChange(of: headset.values[0x69]) { p in if let p, let v = Readback.volumes(p) { levels = [0: Double(v.system), 1: Double(v.media), 2: Double(v.call)] } }
    }
    private func send(_ id: String) { if let c = CommandCatalog.all.first(where: { $0.id == id }) { submit(c) } }
}

struct AdvancedView: View {
    @EnvironmentObject var headset: Headset
    let submit: (DeviceCommand) -> Void
    @State private var code = "02"
    @State private var payload = ""
    @State private var note = ""
    @State private var reviewed = false
    private let allowed: Set<UInt8> = [0x01,0x02,0x03,0x04,0x06,0x07,0x08,0x09,0x0A,0x10,0x11,0x14,0x15,0x16,0x17,0x22,0x23,0x24,0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x39,0x40,0x43,0x44,0x48,0x49,0x50,0x51,0x55,0x56,0x57,0x59,0x61,0x62,0x64,0x67,0x68,0x69,0x70,0x71,0x72,0x95]
    var body: some View {
        GroupBox("進階協定控制") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("開啟 E09 候選功能", isOn: $headset.experimental)
                Text("涵蓋已知指令的自訂參數；不開放 OTA、偽造版本或未使用指令。參數不明的功能保留在此，請先核對 repo 的協定文件。").foregroundStyle(.secondary)
                HStack { TextField("指令 hex，例如 35", text: $code).frame(width: 180); TextField("payload hex，例如 30 31", text: $payload) }
                Toggle("我已核對參數編碼；送出只表示嘗試，不代表已驗證", isOn: $reviewed)
                HStack {
                    Button("送出自訂指令") {
                        guard let c = ProtocolValue.parseHex(code), c.count == 1, allowed.contains(c[0]), let p = ProtocolValue.parseHex(payload) else { note = "指令或 payload 格式錯誤，或此指令不開放"; return }
                        // All custom writes receive the same explicit confirmation as destructive commands.
                        submit(.init(id: "custom", group: "進階", title: "自訂指令 \(code)", code: c[0], payload: p, destructive: true, detail: "自訂參數可能改變裝置設定或清除資料。請核對命令與 payload。")); note = ""
                    }.disabled(!reviewed || !headset.ready || !headset.experimental)
                    Text(note).foregroundStyle(.orange)
                }
            }.padding(14)
        }
    }
}
