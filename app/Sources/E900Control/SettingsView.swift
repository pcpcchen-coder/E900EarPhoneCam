import SwiftUI

struct SettingPicker: View {
    @EnvironmentObject var headset: Headset
    let title: String; let code: UInt8; let choices: [(String, UInt8)]
    let submit: (DeviceCommand) -> Void
    @State private var value = 0
    var body: some View {
        HStack {
            Picker(title, selection: $value) { ForEach(choices.indices, id: \.self) { i in Text(choices[i].0).tag(i) } }
            Button("套用") { submit(.init(id: "setting-\(code)", group: "設定", title: title, code: code, payload: [choices[value].1])) }
            if let p = headset.values[code] { Text("回覆 \(ProtocolValue.hex(p))").font(.caption.monospaced()).foregroundStyle(.secondary) }
        }.disabled(!headset.ready || !headset.experimental)
    }
}

struct SettingsView: View {
    @EnvironmentObject var headset: Headset
    let submit: (DeviceCommand) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("開啟 E09 候選功能", isOn: $headset.experimental)
            Text("選單是準備送出的值；不代表耳機目前設定。按套用後可查看原始回覆，需讀回／實機效果確認才算設定成功。").foregroundStyle(.secondary)
            GroupBox("攝影與裝置") {
                VStack(spacing: 16) {
                    SettingPicker(title: "亮度", code: 0x01, choices: [("低", 48), ("中", 49), ("高", 50)], submit: submit)
                    SettingPicker(title: "佩戴偵測", code: 0x04, choices: [("關閉", 48), ("開啟", 49)], submit: submit)
                    SettingPicker(title: "攝影模式", code: 0x50, choices: [("標準", 48), ("經典", 49)], submit: submit)
                    SettingPicker(title: "鏡頭方向", code: 0x61, choices: [("直向", 48), ("橫向", 49)], submit: submit)
                    HStack { Text("耳機時間"); Spacer(); Button("同步 Mac 時間") { headset.syncClock() }.disabled(!headset.ready || !headset.experimental) }
                    Text("錄影時長 0x02、麥克風 0x03、畫質比例 0x35：參考資料未確立完整位元組編碼／順序，請在進階頁核對後送出；不猜測參數。").font(.caption).foregroundStyle(.secondary)
                }.padding(14)
            }
            GroupBox("手勢配置") {
                VStack(spacing: 16) {
                    ForEach(Array(zip(["向前滑", "向後滑", "單擊", "雙擊", "三擊"], [UInt8(7), 8, 9, 16, 17])), id: \.1) { title, code in
                        SettingPicker(title: title, code: code, choices: [("音量減", 48), ("音量增", 49), ("播放／暫停／接聽／掛斷", 50), ("上一首", 51), ("下一首", 52)], submit: submit)
                    }
                    Button("讀回手勢配置") { if let c = CommandCatalog.all.first(where: { $0.id == "status" }) { submit(c) } }.disabled(!headset.ready || !headset.experimental)
                }.padding(14)
            }
            GroupBox("離線語音與喚醒詞") {
                VStack(spacing: 16) {
                    SettingPicker(title: "手動語音指令", code: 0x06, choices: [("關閉", 48), ("開啟", 49)], submit: submit)
                    SettingPicker(title: "離線語言", code: 0x62, choices: [("中文", 0), ("英文", 1)], submit: submit)
                    SettingPicker(title: "語音助手（反向位元）", code: 0x72, choices: [("離線開／喚醒開", 0), ("離線關／喚醒開", 1), ("離線開／喚醒關", 2), ("離線關／喚醒關", 3)], submit: submit)
                    Text("能力位元及開關編碼源自 E09；E900 需驗證。缺乏喚醒詞能力時，設定不會新增硬體功能。").font(.caption).foregroundStyle(.secondary)
                }.padding(14)
            }
        }
    }
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
                if let caps = headset.capabilities { Text("硬體能力 bitmask：\(String(format: "%08X", caps)) · bit0 即時影像 / bit7 喚醒詞 / bit8 離線語音").font(.caption.monospaced()) }
            }.padding(14)
        }
    }
}
