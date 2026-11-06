import Foundation
import CoreBluetooth

final class Inventory: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var expected: UUID!
    var pending = 0
    var characteristicCount = 0
    var hadError = false
    var finished = false
    var notified: Set<String> = []
    var startedListening = false
    var notifyCount = 0
    var commandCharacteristic: CBCharacteristic?
    var querySent = false
    var wifiScheduled = false
    var wifiSent = false
    var ssidReceived = false
    var responseBuffer = Data()
    func start() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/e900-ble-candidates.json"))
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = root?["second_scan"] as? [[String: Any]] ?? []
            let matches = rows.filter { $0["name"] as? String == "E900-1928" }
            guard matches.count == 1, let raw = matches[0]["local_identifier"] as? String, let id = UUID(uuidString: raw) else {
                print("ERROR: expected exactly one E900-1928 in the previous scan.")
                exit(2)
            }
            expected = id
        } catch { print("ERROR reading scan results: \(error)"); exit(2) }
        print("Target: saved E900-1928. Battery query then ONE OPEN_WIFI AP request (E09-compatible candidate).")
        print("No camera, recording, OTA, or delete commands. This does not join any Wi-Fi network.")
        central = CBCentralManager(delegate: self, queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            guard !self.finished else { return }
            print("Session ended after 10 minutes. AP persistence after BLE disconnect is unverified.")
            self.finish(code: self.ssidReceived ? 0 : 3)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) {
            guard !self.finished, !self.wifiSent else { return }
            print("ERROR: connection/setup timeout. Keep E900 on and iPhone Bluetooth off.")
            self.finish(code: 3)
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Bluetooth state: \(central.state.rawValue); authorization: \(CBCentralManager.authorization.rawValue)")
        if central.state == .poweredOn {
            print("Scanning for the exact device identifier saved locally…")
            central.scanForPeripherals(withServices: nil)
        } else if central.state == .unauthorized || central.state == .unsupported { finish(code: 2) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard target == nil, peripheral.identifier == expected else { return }
        target = peripheral
        peripheral.delegate = self
        central.stopScan()
        print("Found saved E900-1928; RSSI \(RSSI) dBm. Connecting…")
        central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected. Discovering GATT services…")
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("ERROR connecting: \(error?.localizedDescription ?? "unknown")")
        finish(code: 4)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard !finished else { return }
        print("ERROR: disconnected before inventory completed: \(error?.localizedDescription ?? "no reason supplied")")
        finish(code: 4)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("ERROR discovering services: \(error)"); finish(code: 4); return }
        let services = peripheral.services ?? []
        print("Services discovered: \(services.count)")
        pending = services.count
        if services.isEmpty { finish(code: 0); return }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("\nSERVICE \(service.uuid.uuidString)")
        if let error { print("  ERROR: \(error)"); hadError = true }
        for c in service.characteristics ?? [] {
            characteristicCount += 1
            let flags: [(CBCharacteristicProperties, String)] = [(.broadcast,"broadcast"),(.read,"read"),(.writeWithoutResponse,"write-without-response"),(.write,"write"),(.notify,"notify"),(.indicate,"indicate"),(.authenticatedSignedWrites,"signed-write"),(.extendedProperties,"extended-properties"),(.notifyEncryptionRequired,"notify-encryption-required"),(.indicateEncryptionRequired,"indicate-encryption-required")]
            let names = flags.filter { c.properties.contains($0.0) }.map { $0.1 }
            print("  CHAR \(c.uuid.uuidString) [\(names.joined(separator: ", "))]")
        }
        pending -= 1
        if pending == 0 {
            print("\nInventory complete: \(peripheral.services?.count ?? 0) services / \(characteristicCount) characteristics.")
            if hadError { finish(code: 4); return }
            let all = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
            commandCharacteristic = all.first { $0.uuid == CBUUID(string: "AA13") && $0.service?.uuid == CBUUID(string: "AA12") }
            guard commandCharacteristic?.properties.contains(.write) == true else { print("ERROR: AA13 write unavailable"); finish(code: 4); return }
            let desired = [CBUUID(string: "AA14"), CBUUID(string: "AA15")]
            let channels = all.filter { desired.contains($0.uuid) && $0.service?.uuid == CBUUID(string: "AA12") }
            guard channels.count == 2 else { print("ERROR: expected AA14 and AA15."); finish(code: 4); return }
            for c in channels { peripheral.setNotifyValue(true, for: c) }
            if let battery = all.first(where: { $0.uuid == CBUUID(string: "2A19") && $0.service?.uuid == CBUUID(string: "180F") }) {
                peripheral.readValue(for: battery)
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { print("ERROR subscribing \(characteristic.uuid): \(error)"); finish(code: 4); return }
        guard characteristic.isNotifying else { print("ERROR: notification inactive"); finish(code: 4); return }
        notified.insert(characteristic.uuid.uuidString)
        print("NOTIFY active: \(characteristic.uuid.uuidString)")
        guard notified.count == 2, !startedListening else { return }
        startedListening = true
        print("\n=== READY: battery query in 3 seconds; do not press camera buttons ===")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !self.finished else { return }
            self.querySent = true
            self.send(Data([0xAB,0x55,0x00,0x03,0x17,0x00,0x17]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !self.finished, !self.wifiScheduled else { return }
                print("No validated battery response; OPEN_WIFI NOT sent.")
                self.finish(code: 4)
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { print("VALUE ERROR \(characteristic.uuid): \(error)"); return }
        guard let bytes = characteristic.value else { return }
        if characteristic.uuid == CBUUID(string: "2A19") {
            if bytes.count == 1, let value = bytes.first, value <= 100 { print("Standard battery: \(value)%") }
            else { print("Standard battery: unexpected value length \(bytes.count)") }
            return
        }
        notifyCount += 1
        guard notifyCount <= 200 else { return }
        let hex = bytes.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("RX \(ISO8601DateFormatter().string(from: Date())) \(characteristic.uuid.uuidString) len=\(bytes.count): \(hex)\(bytes.count > 64 ? " …(truncated)" : "")")
        guard characteristic.uuid == CBUUID(string: "AA14") else { return }
        responseBuffer.append(bytes)
        while responseBuffer.count >= 4 {
            let b = [UInt8](responseBuffer)
            guard b[0] == 0xAC && b[1] == 0x55 else { responseBuffer = Data(responseBuffer.dropFirst()); continue }
            let length = Int(b[2]) * 256 + Int(b[3])
            guard length >= 2 && length <= 4096 else { responseBuffer = Data(responseBuffer.dropFirst()); continue }
            guard b.count >= length + 4 else { break }
            let frame = Array(b.prefix(length + 4))
            responseBuffer = Data(responseBuffer.dropFirst(length + 4))
            let sum = frame[4..<(frame.count - 1)].reduce(0) { ($0 + Int($1)) & 255 }
            guard sum == Int(frame.last!) else { print("BAD checksum; ignored"); continue }
            let cmd = frame[4]
            let payload = Array(frame[5..<(frame.count - 1)])
            print("VALID frame cmd=\(String(format: "%02X", cmd)), payload length=\(payload.count)")
            if cmd == 0x17 && querySent && !wifiScheduled && !payload.isEmpty {
                wifiScheduled = true
                print("Battery query validated. Sending ONE OPEN_WIFI AP command in 3 seconds.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard !self.finished else { return }
                    self.wifiSent = true
                    self.send(Data([0xAB,0x55,0x00,0x03,0x39,0x30,0x69]))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                        guard !self.finished, !self.ssidReceived else { return }
                        print("No valid SSID response; OPEN_WIFI compatibility remains unconfirmed. No mode guessing or retries.")
                        self.finish(code: 4)
                    }
                }
            } else if cmd == 0x25 && wifiSent {
                let cleaned = Array(payload.reversed().drop(while: { $0 == 0 }).reversed())
                guard !cleaned.isEmpty, cleaned.count <= 32, let ssid = String(bytes: cleaned, encoding: .utf8), !ssid.contains("\n"), !ssid.contains("\r"), !ssid.contains("\0") else {
                    print("Invalid UTF-8 SSID response; ignored."); continue
                }
                ssidReceived = true
                print("\n=== WIFI READY ===")
                print("SSID: \(ssid)")
                print("Keep this program running. Return to chat now; do not change Mac Wi-Fi yet.")
                print("Candidate E09 AP password: 12345678 (not yet verified on E900).")
                let info: [String: Any] = ["ssid": ssid, "mode": "AP", "ip_candidates": ["192.168.169.1", "192.168.49.207"], "observed_at": ISO8601DateFormatter().string(from: Date())]
                do {
                    let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: "/tmp/e900-wifi-info.json"), options: .atomic)
                } catch { print("ERROR saving local Wi-Fi info: \(error)") }
            } else if cmd == 0x42 && payload.count == 2 {
                print("Reported thumbnail count: \(Int(payload[0]) * 256 + Int(payload[1]))")
            }
        }
    }
    func send(_ data: Data) {
        guard let target, let commandCharacteristic else { finish(code: 4); return }
        print("TX AA13: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        target.writeValue(data, for: commandCharacteristic, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { print("WRITE ERROR: \(error)"); finish(code: 4) }
        else { print("GATT write acknowledged; awaiting application events.") }
    }
    func finish(code: Int32) {
        guard !finished else { return }
        finished = true
        central?.stopScan()
        if let target { central?.cancelPeripheralConnection(target) }
        print("Stopped. Battery query: \(querySent); OPEN_WIFI sent: \(wifiSent); SSID received: \(ssidReceived). No delete/finish commands sent.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(code) }
    }
}
setbuf(stdout, nil)
let inventory = Inventory()
inventory.start()
RunLoop.main.run()
