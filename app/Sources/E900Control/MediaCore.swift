import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

struct MediaFile: Identifiable, Hashable {
    let name: String
    let size: String
    let created: String
    var id: String { name }
    var kind: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png": return "照片"
        case "mp4", "mov", "avi": return "影片"
        case "wav", "aac", "mp3": return "錄音"
        default: return "檔案"
        }
    }
}

/// A downloaded file belongs to one specific listing of one host; the same name on another host or
/// a later listing is a different file.
struct MediaKey: Hashable { let listing: UUID; let host: String; let name: String }

enum MediaError: LocalizedError, Equatable {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

enum MediaAPI {
    static func validHost(_ text: String) -> Bool {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { ("0"..."9").contains($0) } && Int($0).map { (0...255).contains($0) } == true }) else { return false }
        let p = pieces.map { Int($0)! }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
    }
    static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 512, !name.contains("%"), !name.contains(":"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func url(host: String, name: String) throws -> URL {
        guard validHost(host), validName(name) else { throw MediaError.message("僅允許私有 IPv4 與安全相對路徑") }
        var c = URLComponents(); c.scheme = "http"; c.host = host; c.path = "/" + name
        guard let url = c.url else { throw MediaError.message("網址格式錯誤") }; return url
    }
    /// Only a direct 200 from the requested host counts; redirects are refused by the session
    /// delegate and surface here as 3xx or a different final URL.
    static func check(_ response: URLResponse?, for url: URL) throws {
        guard let http = response as? HTTPURLResponse else { throw MediaError.message("非 HTTP 回應") }
        guard http.statusCode == 200 else { throw MediaError.message("HTTP \(http.statusCode)\((300...399).contains(http.statusCode) ? "（重新導向已拒絕）" : "")") }
        guard http.url == nil || (http.url?.host == url.host && http.url?.path == url.path) else { throw MediaError.message("回應來自其他位址，已拒絕") }
    }
    static func parseList(_ data: Data) throws -> [MediaFile] {
        var rows: [MediaFile] = []
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let result = root["result"] as? Int, result == 0, let groups = root["info"] as? [[String: Any]] else {
                throw MediaError.message("耳機回傳非成功的檔案清單")
            }
            for group in groups {
                guard let files = group["files"] as? [[String: Any]] else { throw MediaError.message("清單缺少 files 欄位") }
                for file in files {
                    guard let name = file["name"] as? String else { throw MediaError.message("清單缺少 name 欄位") }
                    rows.append(MediaFile(name: name, size: file["size"].map { String(describing: $0) } ?? "—", created: file["createtimestr"] as? String ?? "—"))
                }
            }
        } else {
            rows = try FileListXML.parse(data)
        }
        guard rows.count <= 100_000, rows.allSatisfy({ validName($0.name) }), Set(rows.map(\.name)).count == rows.count else {
            throw MediaError.message("清單含不安全、重複路徑或過多檔案；已拒絕")
        }
        return rows
    }
}

/// XML fallback (`<File><NAME>…</NAME></File>`, never observed on E09/E900 hardware). Error documents
/// must not turn into an empty "successful" list: any status/result element must be 0, error
/// elements fail, and the document root must be a known list/response element.
final class FileListXML: NSObject, XMLParserDelegate {
    static let roots: Set<String> = ["LIST", "FILELIST", "FILES", "ALLFILE", "FUNCTION"]
    static let statusKeys: Set<String> = ["STATUS", "RESULT", "RET", "ERRORCODE", "ERRCODE"]
    static let errorKeys: Set<String> = ["ERROR", "ERRMSG", "ERRORMSG"]
    private(set) var rows: [MediaFile] = []
    private var root: String?
    private(set) var stack: [String] = []
    private var text = ""
    private var fields: [String: String] = [:]
    private var inFile = false
    private var failure: String?

    static func parse(_ data: Data) throws -> [MediaFile] {
        let reader = FileListXML(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        let ok = parser.parse()
        if let failure = reader.failure { throw MediaError.message(failure) }
        guard ok, reader.stack.isEmpty, let root = reader.root, roots.contains(root) else { throw MediaError.message("無法辨識 JSON/XML 檔案清單") }
        return reader.rows
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let key = elementName.uppercased()
        if root == nil { root = key }
        stack.append(key); text = ""
        if Self.errorKeys.contains(key) { fail("耳機回報錯誤（\(elementName)）") }
        if key == "FILE" { fields = [:]; inFile = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let key = elementName.uppercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.statusKeys.contains(key) {
            guard let code = Int(value) else { fail("清單狀態欄位無法辨識：\(value.prefix(40))"); return }
            if code != 0 { fail("耳機回報清單失敗（\(elementName)=\(code)）") }
        }
        if inFile, key != "FILE" { fields[key] = value }
        if key == "FILE" {
            inFile = false
            guard let name = fields["NAME"], !name.isEmpty else { fail("清單項目缺少 NAME"); return }
            rows.append(.init(name: name, size: fields["SIZE"] ?? "—", created: fields["TIME"] ?? "—"))
        }
        _ = stack.popLast(); text = ""
    }
    private func fail(_ message: String) { if failure == nil { failure = message } }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Fetches one URL to a temporary file the caller owns. Throws on non-200, redirect, other host.
protocol MediaTransport: AnyObject { func fetch(_ url: URL) async throws -> URL }
/// Checks a downloaded file can actually be decoded as the expected media kind.
protocol MediaVerifier { func verify(_ file: URL, kind: String) async throws }
struct AcceptAllVerifier: MediaVerifier { func verify(_ file: URL, kind: String) async throws {} }

final class URLSessionTransport: MediaTransport {
    private let session: URLSession
    private let delegate = NoRedirect()
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 600
        configuration.connectionProxyDictionary = [:]; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func fetch(_ url: URL) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let finish: (URL?, Data?, URLResponse?, Error?) -> Void = { temp, body, response, error in
                    if let error { continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error); return }
                    do {
                        try MediaAPI.check(response, for: url)
                        // The system deletes `temp` when the handler returns; move it somewhere we own.
                        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("e900-" + UUID().uuidString)
                        if let temp { try FileManager.default.moveItem(at: temp, to: owned) }
                        else if let body { try body.write(to: owned) }
                        else { throw MediaError.message("沒有收到檔案") }
                        continuation.resume(returning: owned)
                    } catch { continuation.resume(throwing: error) }
                }
                #if canImport(FoundationNetworking)
                // swift-corelibs download tasks do not hand back a file for URLProtocol-served
                // responses; Linux (tests only) buffers in memory instead.
                let task = session.dataTask(with: url) { body, response, error in finish(nil, body ?? Data(), response, error) }
                #else
                let task = session.downloadTask(with: url) { temp, response, error in finish(temp, nil, response, error) }
                #endif
                box.task = task
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: { box.task?.cancel() }
    }
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock(); private var _task: URLSessionTask?
        var task: URLSessionTask? { get { lock.lock(); defer { lock.unlock() }; return _task } set { lock.lock(); _task = newValue; lock.unlock() } }
    }
}

struct DownloadReport: Equatable {
    var saved: [String: URL] = [:]
    var failures: [String] = []
    var cancelled = false
    var total = 0
    var summary: String {
        "已下載並驗證 \(saved.count)/\(total)\(cancelled ? "（已取消）" : "")；耳機原檔保留。" + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
    }
}

/// Download pipeline independent from UI frameworks. Never sends any headset command and never
/// deletes anything except its own temporary files, so originals on the headset are always kept.
struct MediaDownloader {
    let transport: MediaTransport
    let verifier: MediaVerifier
    var fileManager = FileManager.default

    func download(_ rows: [MediaFile], host: String, to folder: URL, progress: (Int, MediaFile) async -> Void = { _, _ in }) async -> DownloadReport {
        var report = DownloadReport(total: rows.count)
        for (i, row) in rows.enumerated() {
            if Task.isCancelled { report.cancelled = true; break }
            await progress(i, row)
            do {
                let temp = try await transport.fetch(MediaAPI.url(host: host, name: row.name))
                defer { try? fileManager.removeItem(at: temp) }
                let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0 else { throw MediaError.message("空檔案") }
                // Give media parsers the original extension inside a unique private temporary path.
                let ext = (row.name as NSString).pathExtension
                var check = fileManager.temporaryDirectory.appendingPathComponent("e900-check-" + UUID().uuidString)
                if !ext.isEmpty { check.appendPathExtension(ext) }
                try fileManager.copyItem(at: temp, to: check)
                defer { try? fileManager.removeItem(at: check) }
                try await verifier.verify(check, kind: row.kind)
                try Task.checkCancellation()
                // UUID prefix avoids collisions, overwrites, nested paths and untrusted symlinks.
                let destination = folder.appendingPathComponent(UUID().uuidString + "-" + (row.name as NSString).lastPathComponent)
                try fileManager.copyItem(at: temp, to: destination)
                report.saved[row.name] = destination
            } catch {
                if error is CancellationError || Task.isCancelled { report.cancelled = true; break }
                report.failures.append("\(row.name)：\(error.localizedDescription)")
            }
        }
        return report
    }
}
