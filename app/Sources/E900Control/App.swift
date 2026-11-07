import AppKit
import SwiftUI

struct E900ControlApp: App {
    @StateObject private var headset = Headset()
    @StateObject private var media = MediaStore()
    var body: some Scene {
        WindowGroup("E900 Control") { ContentView().environmentObject(headset).environmentObject(media).frame(minWidth: 1040, minHeight: 720) }
            .defaultSize(width: 1200, height: 820)
    }
}

struct ContentView: View {
    @EnvironmentObject var headset: Headset
    @State private var page = "總覽"
    @State private var confirmation: DeviceCommand?
    @State private var confirmText = ""
    private let pages = [("總覽", "rectangle.grid.2x2"), ("攝影與錄音", "camera"), ("裝置設定", "slider.horizontal.3"), ("音樂與通話", "headphones"), ("媒體管理", "photo.on.rectangle"), ("語音助手", "waveform"), ("診斷與進階", "wrench.and.screwdriver")]
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("E900").font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("HEADSET CONTROL").font(.caption.monospaced()).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.top, 20)
                List(selection: $page) { ForEach(pages, id: \.0) { item in Label(item.0, systemImage: item.1).tag(item.0).padding(.vertical, 6) } }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label(headset.ready ? "耳機已連線" : "耳機未連線", systemImage: headset.ready ? "circle.fill" : "circle").foregroundStyle(headset.ready ? .green : .secondary)
                    Text("macOS 原生 · CoreBluetooth").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(page).font(.title2.bold()); Text(headset.status).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    if headset.ready { Button("中斷連線") { headset.disconnect() } }
                    else { Button(headset.scanning ? "搜尋中…" : "搜尋裝置") { headset.scan() }.disabled(headset.scanning || headset.connecting) }
                }.padding(24)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if page == "總覽" { overview }
                        if page == "攝影與錄音" { capture }
                        if page == "裝置設定" { SettingsView(submit: submit) }
                        if page == "音樂與通話" { Text("手機音樂與通話還需在系統藍牙配對 A2DP／HFP；BLE 回覆不保證手機播放狀態。").foregroundStyle(.secondary); commandGrid("音樂與通話") }
                        if page == "媒體管理" { MediaView(submit: submit) }
                        if page == "語音助手" { voice }
                        if page == "診斷與進階" { diagnostics }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack { Image(systemName: "info.circle"); Text(headset.latestResult).font(.caption).textSelection(.enabled); Spacer() }.padding(12).background(.bar)
            }
        }
        .tint(.teal)
        .sheet(item: $confirmation) { command in
            VStack(alignment: .leading, spacing: 18) {
                Label(command.title, systemImage: command.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle").font(.title2.bold())
                Text(command.detail)
                Text("將送出 \(ProtocolValue.hex(Frame.encode(command.code, command.payload)))").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if command.destructive { Text("輸入「確認」後才能執行。"); TextField("確認", text: $confirmText) }
                HStack {
                    Spacer(); Button("取消") { confirmation = nil }
                    Button("執行") { headset.run(command); confirmation = nil }.disabled(command.destructive && confirmText != "確認")
                }
            }.padding(28).frame(width: 480)
        }
    }
    private func submit(_ command: DeviceCommand) {
        if command.destructive { confirmText = ""; confirmation = command } else { headset.run(command) }
    }
    private func commandGrid(_ group: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 14)], spacing: 14) {
            ForEach(CommandCatalog.all.filter { $0.group == group }) { command in CommandButton(command: command, submit: submit) }
        }
    }
    private var overview: some View {
        Group {
            HStack(spacing: 14) { Metric(title: "電池", value: headset.battery, icon: "battery.75percent"); Metric(title: "錄影狀態", value: headset.recording, icon: "record.circle"); Metric(title: "錄音狀態", value: headset.audioRecording, icon: "mic"); Metric(title: "佩戴", value: headset.wearing, icon: "person.crop.circle") }
            GroupBox("裝置連線") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("耳機開機後搜尋，選擇你的 E900。若無法連線，先暫停 GlassX 的連線。").foregroundStyle(.secondary)
                    HStack {
                        Picker("附近裝置", selection: $headset.selected) {
                            Text("請選擇").tag(Optional<UUID>.none)
                            ForEach(headset.devices.sorted { a, b in
                                let ae = a.name.uppercased().contains("E900"), be = b.name.uppercased().contains("E900")
                                return ae == be ? a.rssi > b.rssi : ae
                            }) { device in Text("\(device.name) · \(device.rssi) dBm").tag(Optional(device.id)) }
                        }
                        Button("連線") { headset.connect() }.buttonStyle(.borderedProminent).disabled(headset.selected == nil || headset.ready || headset.connecting)
                    }
                }.padding(12)
            }
            Text("快速操作").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205))], spacing: 14) {
                ForEach(CommandCatalog.all.filter { ["photo", "videoStart", "videoStop", "battery"].contains($0.id) }) { CommandButton(command: $0, submit: submit) }
            }
            GroupBox("功能相容性") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("已驗證：電量查詢回覆、拍照、開始／停止錄影", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("其餘依 E09 協定實作，這台 E900 尚待驗證。開啟後可操作候選功能，不代表硬體一定支援。").foregroundStyle(.secondary)
                    Toggle("開啟 E09 候選功能", isOn: $headset.experimental)
                    Text("未連線時，所有狀態保持未知；App 不模擬耳機成功回覆。").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            commandGrid("裝置資訊")
            Text("韌體：\(headset.firmware)\n儲存：\(headset.capacity)\n待處理指令：\(headset.pendingCommands)").font(.callout).textSelection(.enabled)
            CapabilityView()
        }
    }
    private var capture: some View {
        Group {
            Text("錄影、錄音狀態以耳機 ACTION_SYNC 回報為準。照片原始檔請從媒體管理下載。").foregroundStyle(.secondary)
            commandGrid("攝影與錄音")
            ThumbnailView(submit: submit)
            GroupBox("BLE 照片預覽 · 低解析度") {
                if let image = headset.lastPreview {
                    VStack(alignment: .leading) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                        HStack { Text("\(Int(image.size.width))×\(Int(image.size.height)) · BLE 低解析預覽").font(.caption).foregroundStyle(.secondary); Button("另存 JPEG") { headset.savePreview() } }
                    }.padding()
                }
                else { Text("拍照或拉取縮圖後，AA15 傳回的完整且可解碼 JPEG 會顯示在這裡（52 58 包裝已解碼，E900 待實機確認）。\n原始畫質請改用 Wi-Fi 下載。").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160) }
            }
        }
    }
    private var voice: some View {
        Group {
            Text("耳機端語音控制與 Opus 串流工具。AI 辨識、對話與 TTS 服務尚未串接；沒有上傳音訊到雲端。").foregroundStyle(.secondary)
            commandGrid("語音助手")
            HStack {
                Metric(title: "串流狀態", value: headset.voice.label, icon: "dot.radiowaves.left.and.right")
                Metric(title: "接收音訊封包", value: "\(headset.voicePackets)", icon: "waveform")
                Button("匯出 Ogg Opus") { headset.saveVoice() }.disabled(headset.voicePackets == 0)
            }
            Text("主動串流 30 秒後自動要求停止；停止未獲耳機確認前狀態維持「停止中」，最多自動重送 3 次。停止按鈕連線後一律可用。\n匯出依 E09 推定：每個 0x46 封包為一個原始 Opus packet，封裝為 Ogg Opus；若封包不符 Opus 格式會改存原始封包。E900 待實機確認可播放。本機錄音原檔請走 Wi-Fi 下載。").font(.caption).foregroundStyle(.secondary)
            Text("喚醒詞／離線語音開關與語言在「裝置設定」。").font(.callout)
        }
    }
    private var diagnostics: some View {
        Group {
            AdvancedView(submit: submit)
            DisclosureGroup("維護與清除") { commandGrid("維護").padding(.top) }
            GroupBox("韌體更新 / OTA") {
                Text("已知 OTA 命令為 0x63，但尚無經驗證的 E900 韌體、版本相容性及完整性驗證流程。此版本不執行刷寫；避免將其他型號韌體寫入耳機。0x65 版本回報與 0x66 未使用命令也保留在協定文件。").foregroundStyle(.secondary).padding(12)
            }
            HStack { Text("本次診斷（最多 600 筆）").font(.headline); Spacer(); Button("匯出記錄") { headset.exportLog() }; Button("清除顯示") { headset.logs = [] } }
            Text("匯出含 SSID 與協定值，分享前請檢查。照片及音訊內容不寫入診斷記錄。").font(.caption).foregroundStyle(.secondary)
            Text(headset.logs.suffix(120).joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading).padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct Metric: View {
    let title: String; let value: String; let icon: String
    var body: some View { VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()) }.frame(maxWidth: .infinity, minHeight: 70, alignment: .leading).padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14)) }
}
struct CommandButton: View {
    @EnvironmentObject var headset: Headset
    let command: DeviceCommand
    let submit: (DeviceCommand) -> Void
    var body: some View {
        Button { submit(command) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(command.title).font(.headline); Spacer(); if command.destructive { Image(systemName: "exclamationmark.triangle") } }
                Text(command.verified ? "E900 已驗證" : command.isStop ? "停止類 · 連線後隨時可用" : "E09 候選 · 待驗證").font(.caption).foregroundStyle(command.verified ? .green : command.isStop ? .teal : .orange)
            }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(14)
        }.buttonStyle(.bordered).disabled(!headset.ready || (!command.verified && !headset.experimental && !command.isStop))
    }
}

struct ThumbnailView: View {
    @EnvironmentObject var headset: Headset
    let submit: (DeviceCommand) -> Void
    @State private var index = 0
    var body: some View {
        HStack {
            Stepper("縮圖索引：\(index)", value: $index, in: 0...255)
            Button("查詢縮圖狀態") { submit(.init(id: "thumbStatus", group: "攝影", title: "縮圖狀態", code: 0x37, payload: [UInt8(index)])) }
            Button("拉取縮圖") { submit(.init(id: "thumbPull", group: "攝影", title: "拉取縮圖", code: 0x36, payload: [UInt8(index)])) }
        }.disabled(!headset.ready || !headset.experimental)
    }
}

struct CapabilityView: View {
    @EnvironmentObject var headset: Headset
    var body: some View {
        GroupBox("硬體能力（0x95）") {
            VStack(alignment: .leading, spacing: 6) {
                if let mask = headset.capabilities {
                    Text(String(format: "bitmask %08X · 依 E09 位元定義解讀", mask)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Capability.allCases, id: \.rawValue) { cap in
                            let on = Capability.decode(mask).contains(cap)
                            Label(cap.title, systemImage: on ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(on ? .green : .secondary)
                        }
                    }
                } else {
                    Text("尚未讀取。未知時不假設支援；即時影像等功能請先讀取能力。").foregroundStyle(.secondary)
                    Button("讀取硬體能力") { if let c = CommandCatalog.all.first(where: { $0.id == "capabilities" }) { headset.run(c) } }.disabled(!headset.ready || !headset.experimental)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
