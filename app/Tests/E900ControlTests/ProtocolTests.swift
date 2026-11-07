import XCTest
@testable import E900Control

final class ProtocolTests: XCTestCase {
    func testValidatedFrames() {
        XCTAssertEqual(Array(Frame.encode(0x17, [0])), [0xAB,0x55,0,3,0x17,0,0x17])
        XCTAssertEqual(Array(Frame.encode(0x22, [0x31])), [0xAB,0x55,0,3,0x22,0x31,0x53])
        XCTAssertEqual(Array(Frame.encode(0x23)), [0xAB,0x55,0,2,0x23,0x23])
        XCTAssertEqual(Array(Frame.encode(0x24)), [0xAB,0x55,0,2,0x24,0x24])
    }
    func testFragmentationAtEveryBoundary() {
        let wire = Frame.encode(0x17, [0x39,0x37,0], incoming: true)
        for cut in 1..<wire.count {
            var parser = FrameParser()
            XCTAssertTrue(parser.feed(wire.prefix(cut)).isEmpty)
            XCTAssertEqual(parser.feed(wire.dropFirst(cut)), [Frame(command: 0x17, payload: [0x39,0x37,0])])
        }
    }
    func testNoiseChecksumAndCoalescedFrames() {
        var parser = FrameParser()
        let good = Frame.encode(0x24, incoming: true)
        var bad = Array(good); bad[bad.count - 1] = 0
        let bytes = Data([0,1,2,0xAC,0x55,0,1] + bad) + good + good
        XCTAssertEqual(parser.feed(bytes).count, 2)
        XCTAssertGreaterThan(parser.rejected, 0)
    }
    func testBatteryAndInvalidHex() {
        XCTAssertEqual(ProtocolValue.battery([0x39,0x37,0]), 97)
        XCTAssertNil(ProtocolValue.battery([0x3F,0x37,0]))
        XCTAssertNil(ProtocolValue.battery([0x39]))
        XCTAssertEqual(ProtocolValue.parseHex("30 01"), [48,1])
        XCTAssertNil(ProtocolValue.parseHex("3"))
        XCTAssertNil(ProtocolValue.parseHex("XX"))
    }
    func testPhotoOutOfOrderAndDuplicateChunks() {
        var assembler = PhotoAssembler()
        XCTAssertNil(assembler.accept(.init(command: 0x97, payload: [])))
        XCTAssertNil(assembler.accept(.init(command: 0x98, payload: [0,0,0,4,0xFF,0xD9])))
        let start = Frame(command: 0x98, payload: [0,0,0,0,0xFF,0xD8,1,2])
        XCTAssertNil(assembler.accept(start)); XCTAssertNil(assembler.accept(start))
        XCTAssertEqual(assembler.accept(.init(command: 0x99, payload: [0])), Data([0xFF,0xD8,1,2,0xFF,0xD9]))
    }
    func testPhotoGapsAndMaliciousOffsetRejected() {
        var a = PhotoAssembler()
        _ = a.accept(.init(command: 0x97, payload: []))
        _ = a.accept(.init(command: 0x98, payload: [0,0,0,2,0xFF,0xD9]))
        XCTAssertNil(a.accept(.init(command: 0x99, payload: [])))
        _ = a.accept(.init(command: 0x97, payload: []))
        _ = a.accept(.init(command: 0x98, payload: [255,255,255,255,1]))
        XCTAssertNil(a.accept(.init(command: 0x99, payload: [])))
    }
    func testMediaPathAndHostIsolation() throws {
        for name in ["/etc/passwd", "../x", "EVENT/../x", "http://evil/x", "EVENT//x", "EVENT/%2e%2e/x", "EVENT/a\\b", "EVENT/a\nx"] { XCTAssertFalse(MediaAPI.validName(name), name) }
        for host in ["example.com", "8.8.8.8", "127.0.0.1", "192.168.169.1:80", "192.168.999.1", "169.254.1.1"] { XCTAssertFalse(MediaAPI.validHost(host), host) }
        XCTAssertTrue(MediaAPI.validHost("192.168.169.1"))
        XCTAssertEqual(try MediaAPI.url(host: "192.168.169.1", name: "EVENT/hello world.jpg").absoluteString, "http://192.168.169.1/EVENT/hello%20world.jpg")
    }
    func testJSONAndXMLListings() throws {
        let json = Data(#"{"result":0,"info":[{"files":[{"name":"EVENT/a.jpg","size":350}]}]}"#.utf8)
        XCTAssertEqual(try MediaAPI.parseList(json).first?.name, "EVENT/a.jpg")
        XCTAssertEqual(try MediaAPI.parseList(Data("<LIST><File><NAME>EVENT/b.jpg</NAME><SIZE>12</SIZE></File></LIST>".utf8)).first?.size, "12")
        XCTAssertThrowsError(try MediaAPI.parseList(Data(#"{"result":1,"info":[]}"#.utf8)))
        XCTAssertThrowsError(try MediaAPI.parseList(Data(#"{"result":0,"info":[{"files":[{"name":"../x"}]}]}"#.utf8)))
        XCTAssertThrowsError(try MediaAPI.parseList(Data("<html>error</html>".utf8)))
    }
    func testOnlyValidatedCommandsMarkedVerified() {
        XCTAssertEqual(Set(CommandCatalog.all.filter(\.verified).map(\.id)), Set(["battery", "photo", "videoStart", "videoStop"]))
        let clear = CommandCatalog.all.first { $0.id == "deleteAll" }!
        XCTAssertTrue(clear.destructive)
        XCTAssertEqual(clear.payload, [0x30,0])
        XCTAssertFalse(CommandCatalog.all.first { $0.id == "finish" }!.destructive)
    }
    func testXMLErrorDocumentsAreNotEmptySuccess() {
        for doc in ["<Function><Cmd>3015</Cmd><Status>-256</Status></Function>",
                    "<LIST><STATUS>1</STATUS></LIST>",
                    "<LIST><RESULT>abc</RESULT></LIST>",
                    "<LIST><ERROR>busy</ERROR></LIST>",
                    "<LIST><File><SIZE>1</SIZE></File></LIST>",
                    "<html><body><File><NAME>x.jpg</NAME></File></body></html>",
                    "<LIST><File><NAME>a.jpg</NAME>"] {
            XCTAssertThrowsError(try MediaAPI.parseList(Data(doc.utf8)), doc)
        }
        XCTAssertEqual(try MediaAPI.parseList(Data("<Function><Cmd>3015</Cmd><Status>0</Status><LIST></LIST></Function>".utf8)).count, 0)
        XCTAssertEqual(try MediaAPI.parseList(Data("<LIST><ALLFile><File><NAME>EVENT/c.mp4</NAME><TIME>t</TIME></File></ALLFile></LIST>".utf8)).first?.created, "t")
    }
}

final class FileFrameTests: XCTestCase {
    // Hardware PHOTO_START sample from the E09 reference document §2.3.
    let sample: [UInt8] = [0x52,0x58,0x00,0x07,0x97,0x00,0x00,0x2F,0xB8,0x02,0x80,0x58,0x52]

    func testHardwareSampleDecodes() {
        var p = FrameParser(acceptsFileFrames: true)
        XCTAssertEqual(p.feed(Data(sample)), [Frame(command: 0x97, payload: [0x00,0x00,0x2F,0xB8,0x02])])
        XCTAssertEqual(Array(Frame.encodeFile(0x97, [0x00,0x00,0x2F,0xB8,0x02])), sample)
    }
    func testCommandChannelIgnoresFileFrames() {
        var p = FrameParser()
        XCTAssertTrue(p.feed(Data(sample)).isEmpty)
    }
    func testFileFrameFragmentationAndMixing() {
        let wire = Frame.encodeFile(0x98, [0,0,0,0,0xFF,0xD8]) + Frame.encode(0x17, [0x39,0x37,0], incoming: true) + Frame.encodeFile(0x99, [0])
        for cut in 1..<wire.count {
            var p = FrameParser(acceptsFileFrames: true)
            let frames = p.feed(wire.prefix(cut)) + p.feed(wire.dropFirst(cut))
            XCTAssertEqual(frames.map(\.command), [0x98, 0x17, 0x99], "cut \(cut)")
        }
    }
    func testBadFooterAndChecksumRejected() {
        var badFooter = sample; badFooter[12] = 0
        var badCrc = sample; badCrc[10] = 0x81
        var p = FrameParser(acceptsFileFrames: true)
        XCTAssertTrue(p.feed(Data(badFooter + badCrc)).isEmpty)
        XCTAssertGreaterThanOrEqual(p.rejected, 2)
        XCTAssertEqual(p.feed(Data(sample)).count, 1, "parser resynchronises")
    }
    func testPhotoOverFileFramesEndToEnd() {
        let jpeg: [UInt8] = [0xFF,0xD8] + Array(repeating: 7, count: 300) + [0xFF,0xD9]
        var wire = Frame.encodeFile(0x97, [0,0,1,0x30,0])
        for offset in stride(from: 0, to: jpeg.count, by: 120).reversed() {   // out of order
            let chunk = Array(jpeg[offset..<min(offset + 120, jpeg.count)])
            wire += Frame.encodeFile(0x98, [0,0,UInt8(offset >> 8),UInt8(offset & 255)] + chunk)
        }
        wire += Frame.encodeFile(0x99, [0])
        var parser = FrameParser(acceptsFileFrames: true); var assembler = PhotoAssembler(); var out: Data?
        var i = 0
        while i < wire.count {                       // 20-byte notifications
            let end = min(i + 20, wire.count)
            for f in parser.feed(wire.subdata(in: i..<end)) { if let d = assembler.accept(f) { out = d } }
            i = end
        }
        XCTAssertEqual(out, Data(jpeg))
    }
}

final class UpstreamEncodingTests: XCTestCase {
    private func wire(_ c: DeviceCommand?) -> [UInt8] { Array(Frame.encode(c!.code, c!.payload)) }
    private func cmd(_ id: String) -> DeviceCommand { CommandCatalog.all.first { $0.id == id }! }

    func testQueriesCarryOneParameterByteLikeUpstream() {
        XCTAssertEqual(wire(cmd("info")), [0xAB,0x55,0,3,0x55,0,0x55])
        XCTAssertEqual(wire(cmd("capabilities")), [0xAB,0x55,0,3,0x95,0,0x95])
        XCTAssertEqual(wire(cmd("volumes")), [0xAB,0x55,0,3,0x69,0,0x69])
        XCTAssertEqual(wire(cmd("voiceStatus")), [0xAB,0x55,0,3,0x71,0,0x71])
        XCTAssertEqual(wire(cmd("customer")), [0xAB,0x55,0,2,0x64,0x64], "getCustomer is raw, payload-less")
    }
    func testVolumeStepUsesControlVolume() {
        XCTAssertEqual(cmd("up").code, 0x32); XCTAssertEqual(cmd("up").payload, [1])
        XCTAssertEqual(cmd("down").payload, [0])
        XCTAssertEqual(CommandCatalog.setVolume(.media, level: 16)?.payload, [1, 16])
        XCTAssertNil(CommandCatalog.setVolume(.system, level: 16))
        XCTAssertEqual(CommandCatalog.setVolume(.call, level: 3)?.code, 0x70)
    }
    func testRecordDurationIsBigEndianSeconds() {
        XCTAssertEqual(wire(CommandCatalog.recordDuration(seconds: 600)), [0xAB,0x55,0,4,0x02,0x02,0x58,0x5C])
        XCTAssertEqual(CommandCatalog.recordDuration(seconds: 180)?.payload, [0x00,0xB4])
        XCTAssertNil(CommandCatalog.recordDuration(seconds: 90))
        XCTAssertEqual(Readback.recordSeconds([0x01,0x2C]), 300)
    }
    func testCaptureStyleAndVoiceAssistant() {
        XCTAssertEqual(CommandCatalog.captureStyle(is1080p: true, is4x3: false).payload, [49, 48])
        XCTAssertEqual(CommandCatalog.voiceAssistant(offline: true, wake: true).payload, [0])
        XCTAssertEqual(CommandCatalog.voiceAssistant(offline: false, wake: false).payload, [3])
        XCTAssertEqual(CommandCatalog.voiceAssistant(offline: true, wake: false).payload, [2])
        let v = Readback.voiceAssistant([1])!
        XCTAssertFalse(v.offline); XCTAssertTrue(v.wake)
    }
    func testClockMatchesUpstreamLayout() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 9, minute: 5, second: 30))!
        XCTAssertEqual(wire(CommandCatalog.clock(date, calendar: cal)), [0xAB,0x55,0,8,0x59,26,11,7,9,5,30,0x59 &+ 26 &+ 11 &+ 7 &+ 9 &+ 5 &+ 30])
    }
    func testCapabilitiesAndStatus() {
        let mask = Capability.mask([0x00,0x00,0x01,0x81])!
        XCTAssertEqual(Capability.decode(mask), [.live, .aiWakeWord, .offlineVoice])
        XCTAssertNil(Capability.mask([1,2,3]))
        let sync = ActionSync([0,1,1,0,0,0,0,0,1,0])!
        XCTAssertTrue(sync.audio && sync.video); XCTAssertEqual(sync.wearing, true); XCTAssertEqual(sync.importing, false)
        XCTAssertNil(ActionSync([0,0])?.wearing)
        XCTAssertEqual(Readback.pickerValue(code: 0x09, payload: [50]), 50)
        XCTAssertNil(Readback.pickerValue(code: 0x09, payload: []))
        XCTAssertNil(Readback.pickerValue(code: 0x35, payload: [1]))
    }
}
