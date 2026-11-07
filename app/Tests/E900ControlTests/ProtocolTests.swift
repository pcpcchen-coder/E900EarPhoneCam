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
}
