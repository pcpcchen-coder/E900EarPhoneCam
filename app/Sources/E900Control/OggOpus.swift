import Foundation

/// Wraps raw Opus packets (one per 0x46 APP_RECEIVE_VOICE_DATA payload, as treated by the upstream
/// e09-reverse probe) into an Ogg Opus file per RFC 7845. Granule positions come from each packet's
/// TOC byte (RFC 6716 §3.1), so duration does not depend on the unknown capture sample rate; the
/// `inputSampleRate` header field is informational only. E900 packet format is not yet verified.
enum OggOpus {
    enum MuxError: LocalizedError, Equatable {
        case empty, invalidPacket(index: Int)
        var errorDescription: String? {
            switch self {
            case .empty: return "沒有可封裝的 Opus 封包"
            case let .invalidPacket(i): return "第 \(i + 1) 個封包不是有效的 Opus TOC，可能不是原始 Opus；已停止轉檔"
            }
        }
    }

    /// 48 kHz samples in one packet, or nil if the TOC/frame-count byte is invalid.
    static func samples(_ packet: [UInt8]) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frame48k: Int
        switch config {
        case 0...11: frame48k = [480, 960, 1920, 2880][config % 4]           // SILK 10/20/40/60 ms
        case 12...15: frame48k = [480, 960][config % 2]                        // Hybrid 10/20 ms
        default: frame48k = [120, 240, 480, 960][(config - 16) % 4]           // CELT 2.5/5/10/20 ms
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[1] & 0x3F)
            guard frames > 0 else { return nil }
        }
        let total = frame48k * frames
        return total <= 5760 ? total : nil                                     // max 120 ms per packet
    }
    static func channels(_ packet: [UInt8]) -> Int { (packet.first ?? 0) & 4 != 0 ? 2 : 1 }

    static func mux(packets: [[UInt8]], inputSampleRate: UInt32 = 16000, serial: UInt32 = 0x4539_3030) throws -> Data {
        guard !packets.isEmpty else { throw MuxError.empty }
        var durations: [Int] = []
        for (i, p) in packets.enumerated() {
            guard p.count <= 1275 * 3, let n = samples(p) else { throw MuxError.invalidPacket(index: i) }
            durations.append(n)
        }
        let channelCount = UInt8(channels(packets[0]))
        let preSkip: UInt16 = 312
        var head: [UInt8] = Array("OpusHead".utf8) + [1, channelCount]
        head += le(preSkip) + le(inputSampleRate) + [0, 0, 0]                  // gain 0, mapping family 0
        let vendor = Array("E900Control".utf8)
        let tags: [UInt8] = Array("OpusTags".utf8) + le(UInt32(vendor.count)) + vendor + le(UInt32(0))

        var out = Data()
        var sequence: UInt32 = 0
        out += page([head], granule: 0, serial: serial, sequence: &sequence, flags: 0x02)
        out += page([tags], granule: 0, serial: serial, sequence: &sequence, flags: 0)
        var granule: Int64 = 0
        var batch: [[UInt8]] = []
        var segments = 0
        for (i, p) in packets.enumerated() {
            let need = p.count / 255 + 1
            if segments + need > 255 {
                out += page(batch, granule: granule, serial: serial, sequence: &sequence, flags: 0)
                batch = []; segments = 0
            }
            batch.append(p); segments += need; granule += Int64(durations[i])
        }
        out += page(batch, granule: granule, serial: serial, sequence: &sequence, flags: 0x04)
        return out
    }

    private static func page(_ packets: [[UInt8]], granule: Int64, serial: UInt32, sequence: inout UInt32, flags: UInt8) -> Data {
        var lacing: [UInt8] = []
        for p in packets {
            var n = p.count
            while n >= 255 { lacing.append(255); n -= 255 }
            lacing.append(UInt8(n))
        }
        var bytes: [UInt8] = Array("OggS".utf8) + [0, flags]
        bytes += le(UInt64(bitPattern: granule)) + le(serial) + le(sequence) + [0, 0, 0, 0]
        bytes.append(UInt8(lacing.count)); bytes += lacing
        for p in packets { bytes += p }
        let crc = crc32(bytes)
        bytes.replaceSubrange(22..<26, with: le(crc))
        sequence += 1
        return Data(bytes)
    }

    /// Ogg CRC-32: polynomial 0x04C11DB7, init 0, no reflection, no final XOR.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for b in bytes { crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)] }
        return crc
    }
    private static let table: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }
    private static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
}
