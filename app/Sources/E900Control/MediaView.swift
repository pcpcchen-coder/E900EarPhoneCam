import AppKit
import SwiftUI

struct MediaView: View {
    @EnvironmentObject var headset: Headset
    @EnvironmentObject var media: MediaStore
    let submit: (DeviceCommand) -> Void
    @State private var streamPath = "h264"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("1. 開啟耳機 AP → 2. 在 Mac Wi-Fi 設定加入回報的 SSID → 3. 讀取清單並下載。\n參考密碼 12345678、IP 192.168.169.1 / 192.168.49.207 尚未在這台 E900 驗證。").foregroundStyle(.secondary)
            HStack {
                ForEach(CommandCatalog.all.filter { ["wifi", "p2p", "finish"].contains($0.id) }) { c in Button(c.title) { submit(c) }.disabled(!headset.ready || !headset.experimental) }
                Button("開啟 Wi-Fi 設定") { if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") { NSWorkspace.shared.open(url) } }
            }
            Text("耳機 SSID：\(headset.ssid)").font(.headline).textSelection(.enabled)
            HStack {
                TextField("耳機私有 IPv4", text: $media.host).frame(width: 180).disabled(media.busy)
                Button("讀取清單") { media.list() }.disabled(media.busy)
                Button("下載資料夾") { media.chooseFolder() }.disabled(media.busy)
                Button("下載已選取（\(media.selected.count)）") { media.download() }.disabled(media.busy || media.selected.isEmpty || media.folder == nil)
                if media.busy { ProgressView().controlSize(.small); Button("取消") { media.cancel() } }
            }
            if let folder = media.folder { Text("儲存至：\(folder.path)").font(.caption).textSelection(.enabled) }
            Text(media.message).font(.callout).textSelection(.enabled)
            HStack { Button("全選") { media.selected = Set(media.files.map(\.id)) }; Button("取消選取") { media.selected = [] }; Spacer(); Text("下載不清除耳機原檔").foregroundStyle(.secondary) }.disabled(media.busy)
            Table(media.files, selection: $media.selected) {
                TableColumn("名稱", value: \.name).width(min: 220)
                TableColumn("類型", value: \.kind).width(60)
                TableColumn("原始 size", value: \.size).width(90)
                TableColumn("建立時間", value: \.created)
                TableColumn("本機") { row in if media.saved[row.id] != nil { Button("開啟") { media.open(row) } } }.width(60)
            }.frame(minHeight: 260).disabled(media.busy)
            GroupBox("即時預覽 · RTSP") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("需耳機能力 bit0 支援及系統已安裝可處理 RTSP 的播放器（例如 VLC）。此版本以外部播放器顯示，未內嵌串流解碼。").foregroundStyle(.secondary)
                    HStack {
                        Button("啟動耳機即時影像") { if let c = CommandCatalog.all.first(where: { $0.id == "live" }) { submit(c) } }.disabled(!headset.ready || !headset.experimental || headset.capabilities.map { $0 & 1 == 0 } == true)
                        Picker("路徑", selection: $streamPath) { Text("/h264").tag("h264"); Text("/xxx.mov").tag("xxx.mov") }.frame(width: 180)
                        Button("用播放器開啟") {
                            guard MediaAPI.validHost(media.host), let url = URL(string: "rtsp://\(media.host)/\(streamPath)") else { media.message = "請填寫耳機私有 IPv4"; return }
                            if !NSWorkspace.shared.open(url) { media.message = "沒有可用的 RTSP 播放器，請先安裝 VLC" }
                        }
                    }
                }.padding(12)
            }
        }
    }
}
