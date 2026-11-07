import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import E900Control

// MARK: - Fake transport: exercises MediaDownloader without network.

private final class FakeTransport: MediaTransport {
    enum Reply { case body(Data), fail(String), cancelAfter(Data) }
    var replies: [String: Reply] = [:]
    var requested: [URL] = []
    var onFetch: (() -> Void)?
    let dir: URL
    init(dir: URL) { self.dir = dir }
    func fetch(_ url: URL) async throws -> URL {
        requested.append(url); onFetch?()
        switch replies[url.path] ?? .fail("HTTP 404") {
        case let .fail(m): throw MediaError.message(m)
        case let .body(d), let .cancelAfter(d):
            let f = dir.appendingPathComponent("t-" + UUID().uuidString); try d.write(to: f); return f
        }
    }
}
private struct KindVerifier: MediaVerifier {
    /// Treats files whose first byte is 0x00 as undecodable media.
    func verify(_ file: URL, kind: String) async throws {
        XCTAssertFalse(file.pathExtension.isEmpty && kind != "檔案", "verifier needs the original extension")
        if try Data(contentsOf: file).first == 0 { throw MediaError.message("媒體無法解碼") }
    }
}

final class MediaDownloaderTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("e900-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("out"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }
    private func row(_ n: String) -> MediaFile { MediaFile(name: n, size: "1", created: "—") }

    func testPartialFailureKeepsSuccessesAndReportsEach() async throws {
        let t = FakeTransport(dir: tmp)
        t.replies = ["/EVENT/a.jpg": .body(Data([0xFF, 1])), "/EVENT/empty.jpg": .body(Data()),
                     "/EVENT/bad.mp4": .body(Data([0, 1])), "/EVENT/gone.jpg": .fail("HTTP 404")]
        let out = tmp.appendingPathComponent("out")
        let existing = out.appendingPathComponent("a.jpg"); try Data("keep".utf8).write(to: existing)
        let rows = ["EVENT/a.jpg", "EVENT/empty.jpg", "EVENT/bad.mp4", "EVENT/gone.jpg"].map(row)
        let report = await MediaDownloader(transport: t, verifier: KindVerifier()).download(rows, host: "192.168.169.1", to: out)
        XCTAssertEqual(Set(report.saved.keys), ["EVENT/a.jpg"])
        XCTAssertEqual(report.failures.count, 3)
        XCTAssertTrue(report.failures.contains { $0.contains("空檔案") })
        XCTAssertTrue(report.failures.contains { $0.contains("無法解碼") })
        XCTAssertTrue(report.failures.contains { $0.contains("404") })
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8), "existing local file never overwritten")
        let savedURL = report.saved["EVENT/a.jpg"]!
        XCTAssertEqual(savedURL.deletingLastPathComponent().standardizedFileURL, out.standardizedFileURL, "no nested paths")
        XCTAssertTrue(savedURL.lastPathComponent.hasSuffix("-a.jpg"))
        XCTAssertEqual(t.requested.map(\.host), Array(repeating: "192.168.169.1", count: 4))
        XCTAssertTrue(report.summary.contains("耳機原檔保留"))
    }

    func testCancellationStopsBeforeNextFile() async {
        let t = FakeTransport(dir: tmp)
        t.replies = ["/a.jpg": .body(Data([1])), "/b.jpg": .body(Data([1])), "/c.jpg": .body(Data([1]))]
        let out = tmp.appendingPathComponent("out")
        let task = Task { () -> DownloadReport in
            await MediaDownloader(transport: t, verifier: KindVerifier()).download(["a.jpg", "b.jpg", "c.jpg"].map(row), host: "10.0.0.1", to: out) { i, _ in
                if i == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(Set(report.saved.keys), ["a.jpg"])
        XCTAssertLessThanOrEqual(t.requested.count, 2)
    }

    func testUnsafeHostOrNameNeverRequested() async {
        let t = FakeTransport(dir: tmp)
        let out = tmp.appendingPathComponent("out")
        let r1 = await MediaDownloader(transport: t, verifier: KindVerifier()).download([row("a.jpg")], host: "8.8.8.8", to: out)
        let r2 = await MediaDownloader(transport: t, verifier: KindVerifier()).download([row("../a.jpg")], host: "192.168.1.1", to: out)
        XCTAssertTrue(t.requested.isEmpty)
        XCTAssertEqual(r1.failures.count + r2.failures.count, 2)
    }

    func testMediaKeySeparatesHostsAndListings() {
        let l = UUID()
        XCTAssertNotEqual(MediaKey(listing: l, host: "192.168.169.1", name: "a.jpg"), MediaKey(listing: l, host: "192.168.49.207", name: "a.jpg"))
        XCTAssertNotEqual(MediaKey(listing: l, host: "10.0.0.1", name: "a.jpg"), MediaKey(listing: UUID(), host: "10.0.0.1", name: "a.jpg"))
    }

    func testResponseCheck() throws {
        let url = URL(string: "http://192.168.169.1/EVENT/a.jpg")!
        func resp(_ code: Int, _ u: URL = url) -> HTTPURLResponse { HTTPURLResponse(url: u, statusCode: code, httpVersion: nil, headerFields: nil)! }
        XCTAssertNoThrow(try MediaAPI.check(resp(200), for: url))
        XCTAssertThrowsError(try MediaAPI.check(resp(302), for: url))
        XCTAssertThrowsError(try MediaAPI.check(resp(500), for: url))
        XCTAssertThrowsError(try MediaAPI.check(resp(200, URL(string: "http://10.0.0.9/EVENT/a.jpg")!), for: url))
        XCTAssertThrowsError(try MediaAPI.check(nil, for: url))
    }
}

// MARK: - Real URLSession path with a URLProtocol stub (status codes, redirects, cancellation).

final class StubProtocol: URLProtocol {
    struct Stub { var status = 200; var body = Data(); var headers: [String: String] = [:]; var delay: TimeInterval = 0 }
    static var stubs: [String: Stub] = [:]
    static var hits: [String] = []
    private static let lock = NSLock()
    static func reset() { lock.lock(); stubs = [:]; hits = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var stopped = false
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.hits.append(url.absoluteString); let stub = Self.stubs[url.path] ?? Stub(status: 404); Self.lock.unlock()
        let deliver = { [weak self] in
            guard let self, !self.stopped, let client = self.client else { return }
            let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: stub.body)
            client.urlProtocolDidFinishLoading(self)
        }
        if stub.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver) } else { deliver() }
    }
    override func stopLoading() { stopped = true }
}

final class URLSessionTransportTests: XCTestCase {
    override func setUp() { StubProtocol.reset() }
    private func transport() -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(configuration: config)
    }
    private let base = "http://192.168.169.1"

    func testOKDownloadsToOwnedTempFile() async throws {
        StubProtocol.stubs["/app/getfilelist"] = .init(body: Data(#"{"result":0,"info":[{"files":[{"name":"EVENT/a.jpg"}]}]}"#.utf8))
        let file = try await transport().fetch(URL(string: base + "/app/getfilelist")!)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try MediaAPI.parseList(Data(contentsOf: file)).map(\.name), ["EVENT/a.jpg"])
    }

    func testNon200AndRedirectRejected() async {
        StubProtocol.stubs["/x.jpg"] = .init(status: 500, body: Data("err".utf8))
        StubProtocol.stubs["/r.jpg"] = .init(status: 302, body: Data(), headers: ["Location": "http://evil.example/x.jpg"])
        for path in ["/x.jpg", "/r.jpg", "/missing.jpg"] {
            do { _ = try await transport().fetch(URL(string: base + path)!); XCTFail(path) }
            catch { XCTAssertTrue(error.localizedDescription.contains("HTTP"), "\(path): \(error)") }
        }
        XCTAssertFalse(StubProtocol.hits.contains { $0.contains("evil.example") }, "redirect never followed")
    }

    func testCancellationPropagates() async {
        StubProtocol.stubs["/slow.mp4"] = .init(body: Data([1]), delay: 2)
        let t = transport()
        let task = Task { try await t.fetch(URL(string: self.base + "/slow.mp4")!) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("should be cancelled") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testEndToEndDownloadThroughURLSession() async throws {
        StubProtocol.stubs["/EVENT/a.jpg"] = .init(body: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        StubProtocol.stubs["/EVENT/b.jpg"] = .init(status: 404)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("e900-e2e-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let rows = ["EVENT/a.jpg", "EVENT/b.jpg"].map { MediaFile(name: $0, size: "—", created: "—") }
        let report = await MediaDownloader(transport: transport(), verifier: AcceptAllVerifier()).download(rows, host: "192.168.169.1", to: out)
        XCTAssertEqual(Set(report.saved.keys), ["EVENT/a.jpg"], report.failures.joined(separator: "; "))
        let saved = try XCTUnwrap(report.saved["EVENT/a.jpg"])
        XCTAssertEqual(try Data(contentsOf: saved), Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertFalse(StubProtocol.hits.contains { $0.contains("getfilelist") || $0.contains("delete") }, "download never touches other endpoints")
    }
}

// MARK: - Ogg Opus muxer

final class OggOpusTests: XCTestCase {
    func testCRCMatchesOggCheckValue() {
        XCTAssertEqual(OggOpus.crc32(Array("123456789".utf8)), 0x89A1_897F)
    }
    func testTOCDurations() {
        XCTAssertEqual(OggOpus.samples([0x08 << 3]), 480)          // SILK WB 10 ms
        XCTAssertEqual(OggOpus.samples([(9 << 3) | 1]), 1920)      // SILK WB 20 ms ×2
        XCTAssertEqual(OggOpus.samples([(31 << 3) | 3, 6]), 5760)  // CELT 20 ms ×6 = 120 ms
        XCTAssertNil(OggOpus.samples([(31 << 3) | 3, 7]))          // >120 ms invalid
        XCTAssertNil(OggOpus.samples([(31 << 3) | 3]))
        XCTAssertNil(OggOpus.samples([]))
    }
    func testMuxStructureAndGranules() throws {
        let packet: [UInt8] = [9 << 3] + Array(repeating: 0x55, count: 40)   // 20 ms each
        let data = try OggOpus.mux(packets: Array(repeating: packet, count: 300))
        let bytes = [UInt8](data)
        var pages: [(flags: UInt8, granule: UInt64, body: [UInt8])] = []
        var i = 0
        while i < bytes.count {
            XCTAssertEqual(Array(bytes[i..<i + 4]), Array("OggS".utf8))
            let segs = Int(bytes[i + 26]); let lacing = bytes[(i + 27)..<(i + 27 + segs)]
            let bodyLen = lacing.reduce(0) { $0 + Int($1) }
            let pageEnd = i + 27 + segs + bodyLen
            var page = Array(bytes[i..<pageEnd]); let stored = page[22..<26]
            page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
            XCTAssertEqual(withUnsafeBytes(of: OggOpus.crc32(page).littleEndian) { Array($0) }, Array(stored))
            let granule = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[i + 6 + $1]) << (8 * UInt64($1)) }
            pages.append((bytes[i + 5], granule, Array(bytes[(i + 27 + segs)..<pageEnd])))
            i = pageEnd
        }
        XCTAssertEqual(pages.first?.flags, 0x02)
        XCTAssertEqual(Array(pages[0].body.prefix(8)), Array("OpusHead".utf8))
        XCTAssertEqual(pages[0].body[9], 1, "mono")
        XCTAssertEqual(Array(pages[1].body.prefix(8)), Array("OpusTags".utf8))
        XCTAssertEqual(pages.last?.flags, 0x04)
        XCTAssertEqual(pages.last?.granule, 300 * 960)
        XCTAssertGreaterThan(pages.count, 3, "300 packets need several pages")
    }
    func testRejectsNonOpus() {
        XCTAssertThrowsError(try OggOpus.mux(packets: [])) { XCTAssertEqual($0 as? OggOpus.MuxError, .empty) }
        XCTAssertThrowsError(try OggOpus.mux(packets: [[9 << 3, 1], [(31 << 3) | 3]])) { XCTAssertEqual($0 as? OggOpus.MuxError, .invalidPacket(index: 1)) }
    }
}
