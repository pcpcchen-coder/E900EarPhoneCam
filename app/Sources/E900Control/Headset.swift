import AppKit
import CoreBluetooth
import SwiftUI

struct DiscoveredDevice: Identifiable {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var id: UUID { peripheral.identifier }
}

final class Headset: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var devices: [DiscoveredDevice] = []
    @Published var selected: UUID?
    @Published var status = "準備藍牙"
    @Published var ready = false
    @Published var scanning = false
    @Published var connecting = false
    @Published var experimental = false
    @Published var battery = "尚未讀取"
    @Published var recording = "未知"
    @Published var audioRecording = "未知"
    @Published var firmware = "尚未讀取"
    @Published var capacity = "尚未讀取（單位待確認）"
    @Published var ssid = "等待耳機回報"
    @Published var capabilities: UInt32?
    @Published var values: [UInt8: [UInt8]] = [:]
    @Published var logs: [String] = []
    @Published var lastPreview: NSImage?
    @Published var voicePackets = 0
    @Published var voiceActive = false
    @Published var latestResult = "尚未送出指令"
    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var writer: CBCharacteristic?
    private var subscriptions = Set<String>()
    private var parsers: [String: FrameParser] = [:]
    private var photo = PhotoAssembler()
    private var photoTimer: Timer?
    private var voiceTimer: Timer?
    private var voiceCapture = Data()
    private var queue: [DeviceCommand] = []
    private var inFlight: DeviceCommand?
    private var commandTimer: Timer?
    private var setupTimer: Timer?
    private var session = UUID()

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func log(_ message: String) {
        logs.append("\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))  \(message)")
        if logs.count > 600 { logs.removeFirst(logs.count - 600) }
    }
    func scan() {
        guard central.state == .poweredOn, target == nil else { return }
        devices = []; scanning = true; status = "搜尋附近裝置（請選擇你的 E900）"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let token = UUID(); session = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.session == token, self.scanning else { return }
            self.central.stopScan(); self.scanning = false; self.status = "搜尋結束，找到 \(self.devices.count) 台裝置"
        }
    }
    func connect() {
        guard central.state == .poweredOn, target == nil,
              let row = devices.first(where: { $0.id == selected }) else { return }
        central.stopScan(); scanning = false; connecting = true; target = row.peripheral
        target?.delegate = self; status = "連線中：\(row.name)"; session = UUID()
        central.connect(row.peripheral)
        setupTimer?.invalidate()
        setupTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self, !self.ready else { return }
            self.log("連線或通知訂閱逾時，請關閉 GlassX 後重試")
            self.disconnect()
        }
    }
    func disconnect() {
        central.stopScan(); scanning = false
        if let target { central.cancelPeripheralConnection(target) }
        clearSession(); status = "已中斷連線"
    }
    private func clearSession() {
        session = UUID(); ready = false; connecting = false; writer = nil; target = nil
        subscriptions = []; parsers = [:]; photo.reset(); queue = []; inFlight = nil
        commandTimer?.invalidate(); setupTimer?.invalidate(); voiceTimer?.invalidate(); photoTimer?.invalidate()
        voiceActive = false; recording = "未知"; audioRecording = "未知"; capabilities = nil
        values = [:]; ssid = "等待耳機回報"; battery = "尚未讀取"; firmware = "尚未讀取"
        capacity = "尚未讀取（單位待確認）"; lastPreview = nil
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: status = "藍牙已開啟，按搜尋裝置"
        case .poweredOff: clearSession(); scanning = false; status = "請開啟 Mac 藍牙"
        case .unauthorized: clearSession(); scanning = false; status = "請在系統設定 → 隱私權與安全性 → 藍牙，允許 E900 Control"
        case .unsupported: clearSession(); status = "目前環境無法存取藍牙；請直接開啟 .app"
        default: clearSession(); status = "藍牙尚未就緒（\(central.state.rawValue)）"
        }
        log(status)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名裝置"
        let row = DiscoveredDevice(peripheral: peripheral, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == row.id }) { devices[index] = row }
        else { devices.append(row) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === target else { return }
        status = "檢查耳機服務與通知"; peripheral.discoverServices([CBUUID(string: "AA12")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === target else { return }
        clearSession(); status = "連線失敗：\(error?.localizedDescription ?? "未知原因")"; log(status)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === target else { return }
        clearSession(); status = "耳機已斷線"; log(error?.localizedDescription ?? status)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === target else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "AA12") }) else {
            log("找不到 E900 的 AA12 服務"); disconnect(); return
        }
        peripheral.discoverCharacteristics([CBUUID(string: "AA13"), CBUUID(string: "AA14"), CBUUID(string: "AA15")], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === target else { return }
        let chars = service.characteristics ?? []
        writer = chars.first { $0.uuid == CBUUID(string: "AA13") && $0.properties.contains(.write) }
        let readers = chars.filter { [CBUUID(string: "AA14"), CBUUID(string: "AA15")].contains($0.uuid) && $0.properties.contains(.notify) }
        guard error == nil, writer != nil, readers.count == 2 else { log("耳機 GATT 不相容"); disconnect(); return }
        for c in readers { peripheral.setNotifyValue(true, for: c) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard peripheral === target else { return }
        guard error == nil, c.isNotifying else { log("通知訂閱失敗"); disconnect(); return }
        subscriptions.insert(c.uuid.uuidString)
        if subscriptions.count == 2, !ready {
            ready = true; connecting = false; setupTimer?.invalidate(); status = "已連線：\(peripheral.name ?? "E900")"
            log("AA13 / AA14 / AA15 就緒；不自動傳送設定")
            run(CommandCatalog.all.first { $0.id == "battery" }!)
        }
    }
    func run(_ command: DeviceCommand) {
        guard ready else { latestResult = "請先連線耳機"; return }
        let stop = [UInt8(0x24), 0x56, 0x49].contains(command.code) || (command.code == 0x34 && command.payload == [0])
        guard command.verified || experimental || stop else { latestResult = "請先開啟 E09 候選功能"; return }
        guard queue.count < 20 else { latestResult = "指令佇列已滿，請稍後"; return }
        if command.code == 0x67, let caps = capabilities, caps & 1 == 0 {
            latestResult = "耳機能力回報不支援即時影像"; return
        }
        if stop { queue.insert(command, at: 0) } else { queue.append(command) }
        pump()
    }
    private func pump() {
        guard inFlight == nil, ready, !queue.isEmpty, let target, let writer else { return }
        let command = queue.removeFirst(); let data = Frame.encode(command.code, command.payload)
        guard data.count <= target.maximumWriteValueLength(for: .withResponse) else { log("指令超過單次寫入上限"); pump(); return }
        inFlight = command
        latestResult = "送出：\(command.title)；等待耳機回覆"
        log("TX \(command.title) [\(ProtocolValue.hex(data))]")
        target.writeValue(data, for: writer, type: .withResponse)
        commandTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, let current = self.inFlight else { return }
            self.latestResult = "\(current.title)：未收到可確認的回覆，結果未知（不自動重送）"
            self.log(self.latestResult); self.inFlight = nil; self.pump()
        }
        if command.code == 0x57 || command.code == 0x0A {
            voiceCapture = Data(); voicePackets = 0; voiceActive = true
            voiceTimer?.invalidate()
            voiceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                self?.run(.init(id: "autoVoiceStop", group: "語音助手", title: "30 秒串流停止", code: 0x56, payload: [0]))
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === target else { return }
        if let error {
            latestResult = "GATT 寫入失敗：\(error.localizedDescription)"; log(latestResult)
            commandTimer?.invalidate(); inFlight = nil; pump()
        } else { log("GATT 已接受寫入；不代表功能已完成") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard peripheral === target else { return }
        guard error == nil, let data = c.value else { log("通知讀取失敗"); return }
        let key = c.uuid.uuidString
        var parser = parsers[key] ?? FrameParser()
        let before = parser.rejected; let frames = parser.feed(data); parsers[key] = parser
        if parser.rejected > before { log("丟棄校驗失敗的 \(key) 封包") }
        if frames.isEmpty, data.starts(with: [0x52, 0x58]) { log("AA15 RX 包裝格式已觀察到，未解碼；等待 AC55 資料幀") }
        for frame in frames { receive(frame, channel: key) }
    }
    private func receive(_ frame: Frame, channel: String) {
        let p = frame.payload; let code = frame.command
        if code != 0x98 && code != 0x46 { log("RX \(channel) \(String(format: "%02X", code)) [\(ProtocolValue.hex(p.prefix(48)))]") }
        if channel == "AA14" {
            values[code] = p
            if let pending = inFlight, code == pending.code || (code == 0x25 && [0x39, 0x67].contains(pending.code)) || (code == 0x42 && pending.code == 0x40) {
                commandTimer?.invalidate()
                latestResult = "\(pending.title)：收到協定回覆；實際效果請確認裝置／狀態"
                inFlight = nil; pump()
            }
            switch code {
            case 0x17:
                if let value = ProtocolValue.battery(p) { battery = "\(value)%\(p[2] == 1 ? " · 充電中" : "")（E09 解碼）" }
            case 0x53:
                if p.count >= 2, p[1] <= 100 { battery = "\(p[1])%\(p[0] == 1 ? " · 充電中" : "")" }
            case 0x16: if p.count == 2 { capacity = "\(Int(p[0]) << 8 | Int(p[1]))（原始值，單位未確認）" }
            case 0x55: if p.count >= 7 { firmware = "BT \(p[0]).\(p[1]).\(p[2]) / ISP \(p[3]).\(p[4]).\(p[5]) / 裝置 \(p[6])" }
            case 0x95: if p.count == 4 { capabilities = p.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
            case 0x25:
                let cleaned = Array(p.reversed().drop(while: { $0 == 0 }).reversed())
                if !cleaned.isEmpty, cleaned.count <= 32, let s = String(bytes: cleaned, encoding: .utf8), !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { ssid = s }
            case 0x45:
                if p.count >= 3 { audioRecording = p[1] == 1 ? "錄音中" : "未錄音"; recording = p[2] == 1 ? "錄影中" : "未錄影" }
            default: break
            }
        }
        if channel == "AA15", [UInt8(0x97), 0x98, 0x99].contains(code) {
            if code == 0x97 {
                photoTimer?.invalidate()
                photoTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.photo.reset(); self?.log("BLE 縮圖接收逾時，未交付不完整圖片") }
            }
            if let jpeg = photo.accept(frame), let image = NSImage(data: jpeg) {
                photoTimer?.invalidate(); lastPreview = image; log("BLE 縮圖完成：\(jpeg.count) bytes，非原始畫質")
            }
        }
        if code == 0x46, voiceActive, voiceCapture.count < 2_000_000 {
            // Preserve packet boundaries; this is NOT a playable Ogg/Opus file.
            let n = p.count; voiceCapture.append(contentsOf: [UInt8(n >> 8), UInt8(n & 255)] + p); voicePackets += 1
        }
        if [UInt8(0x56), 0x49].contains(code) { voiceActive = false; voiceTimer?.invalidate() }
    }
    func saveVoice() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "E900-voice.opuspackets"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try voiceCapture.write(to: url, options: .atomic); log("已保存 Opus 封包；每包前有 2-byte BE 長度，需後續解碼") }
        catch { log("保存失敗：\(error.localizedDescription)") }
    }
    func exportLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "E900-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try logs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { log("匯出失敗：\(error.localizedDescription)") }
    }
    func syncClock() {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let y = (c.year ?? 2000) - 2000
        guard (0...255).contains(y) else { return }
        run(.init(id: "clock", group: "設定", title: "同步 Mac 時間", code: 0x59, payload: [y, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0].map(UInt8.init)))
    }
}
