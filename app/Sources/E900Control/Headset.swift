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
    @Published var wearing = "未知"
    @Published var firmware = "尚未讀取"
    @Published var capacity = "尚未讀取（單位待確認）"
    @Published var ssid = "等待耳機回報"
    @Published var capabilities: UInt32?
    @Published var values: [UInt8: [UInt8]] = [:]
    @Published var logs: [String] = []
    @Published var lastPreview: NSImage?
    @Published var lastPreviewJPEG: Data?
    @Published var voicePackets = 0
    @Published var voice = VoiceSession()
    @Published var pendingCommands = 0
    @Published var latestResult = "尚未送出指令"
    var voiceActive: Bool { voice.isActive }
    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var writer: CBCharacteristic?
    private var subscriptions = Set<String>()
    private var parsers: [String: FrameParser] = [:]
    private var photo = PhotoAssembler()
    private var photoTimer: Timer?
    private var voiceTimer: Timer?
    private var voicePacketsData: [[UInt8]] = []
    private var voiceBytes = 0
    private var commands = CommandCoordinator()
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
        subscriptions = []; parsers = [:]; photo.reset()
        let dropped = commands.reset()
        if !dropped.isEmpty { log("斷線：取消 \(dropped.count) 筆未完成指令（不會在重新連線後重送）") }
        pendingCommands = 0
        commandTimer?.invalidate(); setupTimer?.invalidate(); voiceTimer?.invalidate(); photoTimer?.invalidate()
        voice.disconnected(); recording = "未知"; audioRecording = "未知"; wearing = "未知"; capabilities = nil
        values = [:]; ssid = "等待耳機回報"; battery = "尚未讀取"; firmware = "尚未讀取"
        capacity = "尚未讀取（單位待確認）"; lastPreview = nil; lastPreviewJPEG = nil
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

    // MARK: commands

    func run(_ command: DeviceCommand) {
        guard ready else { latestResult = "請先連線耳機"; return }
        guard command.verified || experimental || command.isStop else { latestResult = "請先開啟 E09 候選功能"; return }
        if command.code == 0x67 {
            guard let caps = capabilities else { latestResult = "請先讀取硬體能力（0x95）；能力未知時不啟動即時影像"; return }
            guard caps & 1 != 0 else { latestResult = "耳機能力回報不支援即時影像"; return }
        }
        if command.stopsVoiceStream, !voice.stopRequested(), voice.isActive {
            latestResult = "停止指令已送出，等待耳機確認"; return
        }
        switch commands.enqueue(command) {
        case .queueFull: latestResult = "指令佇列已滿，請稍後（停止指令不受此限制）"; return
        case .duplicateStop: latestResult = "\(command.title)已在佇列中"; return
        case .queued: break
        }
        if let abandoned = commands.preemptForStop(now: Date()) {
            commandTimer?.invalidate()
            log("\(abandoned.title)：為優先送出停止指令而放棄等待，結果未知")
            settled(abandoned.command, success: false)
        }
        pump()
    }
    private func pump() {
        pendingCommands = commands.pendingCount
        guard ready, let target, let writer, let flight = commands.next(now: Date()) else { return }
        let command = flight.ticket.command
        let data = Frame.encode(command.code, command.payload)
        guard data.count <= target.maximumWriteValueLength(for: .withResponse) else {
            log("指令超過單次寫入上限：\(command.title)"); _ = commands.writeFailed(); settled(command, success: false); pump(); return
        }
        latestResult = "送出：\(command.title)；等待耳機回覆"
        log("TX \(command.title) [\(ProtocolValue.hex(data))]\(flight.ticket.ambiguous ? "（前一筆同類指令逾時，回覆可能混淆）" : "")")
        target.writeValue(data, for: writer, type: .withResponse)
        let serial = flight.ticket.serial
        commandTimer?.invalidate()
        commandTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, flight.deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            guard let self, let expired = self.commands.timeout(serial: serial, now: Date()) else { return }
            self.latestResult = "\(expired.command.title)：未收到可確認的回覆，結果未知（不自動重送）"
            self.log(self.latestResult)
            self.settled(expired.command, success: false)
            self.pump()
        }
        if command.startsVoiceStream { beginVoice() }
        pendingCommands = commands.pendingCount
    }
    /// Command finished without a confirmed reply (timeout, write error, pre-emption).
    private func settled(_ command: DeviceCommand, success: Bool) {
        guard !success, command.stopsVoiceStream else { return }
        if voice.stopFailed(), voice.stopRequested() {
            log("停止串流未確認，再送一次停止")
            if let stop = CommandCatalog.all.first(where: { $0.id == "voiceStop" }) { enqueueStopRetry(stop) }
        } else if voice.isActive {
            latestResult = "停止串流未確認；耳機可能仍在串流，請再按停止"
        }
    }
    private func enqueueStopRetry(_ stop: DeviceCommand) {
        if case .queued = commands.enqueue(stop) { _ = commands.preemptForStop(now: Date()); pump() }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === target else { return }
        if let error {
            latestResult = "GATT 寫入失敗：\(error.localizedDescription)"; log(latestResult)
            commandTimer?.invalidate()
            if let failed = commands.writeFailed() { settled(failed.command, success: false) }
            pump()
        } else { log("GATT 已接受寫入；不代表功能已完成") }
    }

    // MARK: notifications

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard peripheral === target else { return }
        guard error == nil, let data = c.value else { log("通知讀取失敗"); return }
        let key = c.uuid.uuidString
        var parser = parsers[key] ?? FrameParser(acceptsFileFrames: key == "AA15")
        let before = parser.rejected; let frames = parser.feed(data); parsers[key] = parser
        if parser.rejected > before { log("丟棄校驗失敗的 \(key) 封包") }
        for frame in frames { receive(frame, channel: key) }
    }
    private func receive(_ frame: Frame, channel: String) {
        let p = frame.payload; let code = frame.command
        if code != 0x98 && code != 0x46 { log("RX \(channel) \(String(format: "%02X", code)) [\(ProtocolValue.hex(p.prefix(48)))]") }
        if channel == "AA14" {
            values[code] = p
            switch commands.reply(code: code, now: Date()) {
            case let .matched(ticket, confirmed):
                commandTimer?.invalidate()
                latestResult = confirmed
                    ? "\(ticket.command.title)：收到協定回覆；實際效果請確認裝置／狀態"
                    : "\(ticket.command.title)：收到回覆，但可能是前一筆逾時指令的遲到回覆；結果未確認"
                pump()
            case let .late(lateCode):
                log("收到 \(String(format: "%02X", lateCode)) 遲到回覆；不套用到目前指令")
            case .unsolicited: break
            }
            updateState(code: code, payload: p)
        }
        if channel == "AA15", [UInt8(0x97), 0x98, 0x99].contains(code) {
            if code == 0x97 {
                photoTimer?.invalidate()
                photoTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.photo.reset(); self?.log("BLE 縮圖接收逾時，未交付不完整圖片") }
            }
            if let jpeg = photo.accept(frame) {
                photoTimer?.invalidate()
                if let image = NSImage(data: jpeg) { lastPreview = image; lastPreviewJPEG = jpeg; log("BLE 預覽完成：\(jpeg.count) bytes，低解析度，非原始畫質") }
                else { log("BLE 預覽組裝完成但 JPEG 無法解碼，已丟棄") }
            } else if code == 0x99 { log("BLE 預覽不完整或格式錯誤，未交付") }
        }
        if code == 0x46 {
            if voice.acceptsPackets {
                voice.packetReceived()
                if voiceBytes + p.count <= 2_000_000 { voicePacketsData.append(p); voiceBytes += p.count; voicePackets += 1 }
            } else if voicePackets == 0 || voicePackets % 200 == 0 { log("收到未啟動串流的 0x46 音訊封包，未保存") }
        }
    }
    private func updateState(code: UInt8, payload p: [UInt8]) {
        switch code {
        case 0x17:
            if let value = ProtocolValue.battery(p) { battery = "\(value)%\(p[2] == 1 ? " · 充電中" : "")（E09 解碼）" }
        case 0x53:
            if p.count >= 2, p[1] <= 100 { battery = "\(p[1])%\(p[0] == 1 ? " · 充電中" : "")" }
        case 0x16: if p.count == 2 { capacity = "\(Int(p[0]) << 8 | Int(p[1]))（原始值，單位未確認）" }
        case 0x55: if p.count >= 7 { firmware = "BT \(p[0]).\(p[1]).\(p[2]) / ISP \(p[3]).\(p[4]).\(p[5]) / 裝置 \(p[6])" }
        case 0x95: if let mask = Capability.mask(p) { capabilities = mask }
        case 0x25:
            let cleaned = Array(p.reversed().drop(while: { $0 == 0 }).reversed())
            if !cleaned.isEmpty, cleaned.count <= 32, let s = String(bytes: cleaned, encoding: .utf8), !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { ssid = s }
        case 0x45:
            if let sync = ActionSync(p) {
                audioRecording = sync.audio ? "錄音中" : "未錄音"; recording = sync.video ? "錄影中" : "未錄影"
                if let w = sync.wearing { wearing = w ? "佩戴中" : "未佩戴" }
            }
        // Any stop/cancel acknowledgement means the headset ended the stream, even if it is a late
        // reply to an earlier attempt.
        case 0x56, 0x49: if voice.isActive { stopVoiceConfirmed() }
        case 0x04: if let v = p.first { wearing = v == 49 ? "偵測開啟" : "偵測關閉" }
        // AA14 0x97/0x99 are voice-data start/end (wake word), not photo frames.
        case 0x97: if let token = voice.wakeStarted() { voicePacketsData = []; voiceBytes = 0; voicePackets = 0; armVoiceTimer(token, seconds: 60); log("耳機開始傳送語音（被動喚醒）") }
        case 0x99: if voice.isPassive { voice.wakeEnded(); voiceTimer?.invalidate(); log("耳機語音傳送結束，共 \(voicePackets) 包") }
        default: break
        }
    }

    // MARK: voice stream

    private func beginVoice() {
        voicePacketsData = []; voiceBytes = 0; voicePackets = 0
        armVoiceTimer(voice.startSent(), seconds: 30)
    }
    private func armVoiceTimer(_ token: UUID, seconds: TimeInterval) {
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.voice.isPassive, self.voice.token == token { self.voice.wakeEnded(); self.log("被動語音 60 秒未結束，停止保存"); return }
            guard self.voice.autoStopFired(token: token),
                  let stop = CommandCatalog.all.first(where: { $0.id == "voiceStop" }) else { return }
            self.log("串流已達上限，自動要求停止")
            self.enqueueStopRetry(stop)
        }
    }
    private func stopVoiceConfirmed() {
        voice.stopConfirmed(); voiceTimer?.invalidate()
        log("耳機確認停止串流，共 \(voicePackets) 包")
    }
    func saveVoice() {
        let packets = voicePacketsData
        let panel = NSSavePanel(); panel.nameFieldStringValue = "E900-voice.opus"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let ogg = try OggOpus.mux(packets: packets)
            try ogg.write(to: url, options: .atomic)
            log("已保存 Ogg Opus（\(packets.count) 包，E09 推定格式；E900 待實機確認可播放）")
        } catch {
            // Fallback keeps the raw evidence: 2-byte BE length + packet, NOT playable.
            var raw = Data()
            for p in packets { raw.append(contentsOf: [UInt8(p.count >> 8), UInt8(p.count & 255)] + p) }
            let rawURL = url.deletingPathExtension().appendingPathExtension("opuspackets")
            do { try raw.write(to: rawURL, options: .atomic); log("無法轉成 Ogg（\(error.localizedDescription)）；已改存原始封包 \(rawURL.lastPathComponent)") }
            catch { log("保存失敗：\(error.localizedDescription)") }
        }
    }
    func savePreview() {
        guard let jpeg = lastPreviewJPEG else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "E900-ble-preview-lowres.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try jpeg.write(to: url, options: .atomic) } catch { log("保存失敗：\(error.localizedDescription)") }
    }
    func exportLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "E900-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try logs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { log("匯出失敗：\(error.localizedDescription)") }
    }
    func syncClock() {
        guard let command = CommandCatalog.clock(Date()) else { return }
        run(command)
    }
}

private extension CommandCoordinator.Ticket { var title: String { command.title } }
