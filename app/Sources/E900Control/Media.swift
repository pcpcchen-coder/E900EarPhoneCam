import AppKit
import AVFoundation
import Foundation

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
enum MediaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
enum MediaAPI {
    static func validHost(_ text: String) -> Bool {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }) else { return false }
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
            let reader = FileListXML(); let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false; parser.delegate = reader
            guard parser.parse(), reader.sawRoot else { throw MediaError.message("無法辨識 JSON/XML 檔案清單") }
            rows = reader.rows
        }
        guard rows.count <= 100_000, rows.allSatisfy({ validName($0.name) }), Set(rows.map(\.name)).count == rows.count else {
            throw MediaError.message("清單含不安全、重複路徑或過多檔案；已拒絕")
        }
        return rows
    }
}
final class FileListXML: NSObject, XMLParserDelegate {
    var rows: [MediaFile] = []; var sawRoot = false
    private var fields: [String: String] = [:]; private var key = ""; private var inside = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        key = elementName.uppercased()
        if ["LIST", "FILELIST", "FILES"].contains(key) { sawRoot = true }
        if key == "FILE" { fields = [:]; inside = true; sawRoot = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inside { fields[key, default: ""] += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.uppercased() == "FILE" {
            rows.append(.init(name: fields["NAME", default: ""].trimmingCharacters(in: .whitespacesAndNewlines), size: fields["SIZE"] ?? "—", created: fields["TIME"] ?? "—")); inside = false
        }
        key = ""
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class MediaStore: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "mediaHost") ?? "192.168.169.1"
    @Published var files: [MediaFile] = []
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var message = "連上耳機 Wi-Fi 後讀取檔案清單"
    @Published var folder: URL?
    @Published var saved: [String: URL] = [:]
    private var listedHost: String?
    private var operation: Task<Void, Never>?
    private let delegate = NoRedirect()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 600
        c.connectionProxyDictionary = [:]; c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
    }()
    private func fetch(_ url: URL) async throws -> URL {
        let (temp, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.host == url.host else { try? FileManager.default.removeItem(at: temp); throw MediaError.message("HTTP 回應失敗或重新導向被拒絕") }
        return temp
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "選擇下載資料夾"
        if panel.runModal() == .OK { folder = panel.url }
    }
    func list() {
        guard !busy else { return }
        let requestedHost = host
        busy = true; files = []; selected = []; listedHost = nil; message = "讀取中…"
        operation = Task {
            defer { busy = false }
            do {
                let url = try MediaAPI.url(host: requestedHost, name: "app/getfilelist")
                let temp = try await fetch(url); defer { try? FileManager.default.removeItem(at: temp) }
                let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw MediaError.message("清單過大，已拒絕") }
                try Task.checkCancellation()
                files = try MediaAPI.parseList(Data(contentsOf: temp)); listedHost = requestedHost
                UserDefaults.standard.set(requestedHost, forKey: "mediaHost")
                message = "已讀取 \(files.count) 個檔案；size 是耳機原始欄位，單位尚未確認"
            } catch { message = "讀取失敗：\(error.localizedDescription)" }
        }
    }
    func download() {
        guard !busy, let folder else { message = "請先選擇下載資料夾"; return }
        guard listedHost == host else { message = "IP 已變更，請重新讀取清單"; return }
        let rows = files.filter { selected.contains($0.id) }; let requestedHost = host
        guard !rows.isEmpty else { message = "請先選擇檔案"; return }
        busy = true
        operation = Task {
            defer { busy = false }
            var success = 0; var errors: [String] = []
            for (i, row) in rows.enumerated() {
                do {
                    try Task.checkCancellation()
                    message = "下載 \(i + 1)/\(rows.count)：\(row.name)"
                    let temp = try await fetch(MediaAPI.url(host: requestedHost, name: row.name))
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0 else { throw MediaError.message("空檔案") }
                    // Give media parsers the original extension while retaining a unique private temporary path.
                    let check = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((row.name as NSString).pathExtension)
                    try FileManager.default.copyItem(at: temp, to: check); defer { try? FileManager.default.removeItem(at: check) }
                    if row.kind == "照片" {
                        guard NSImage(contentsOf: check) != nil else { throw MediaError.message("圖片無法解碼") }
                    } else if row.kind == "影片" || row.kind == "錄音" {
                        let asset = AVURLAsset(url: check)
                        let duration = try await asset.load(.duration)
                        let tracks = try await asset.loadTracks(withMediaType: row.kind == "影片" ? .video : .audio)
                        guard duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else { throw MediaError.message("媒體串流或時長無效") }
                    }
                    try Task.checkCancellation()
                    // UUID prefix avoids collisions, overwrites, nested paths and untrusted symlinks.
                    let destination = folder.appendingPathComponent(UUID().uuidString + "-" + (row.name as NSString).lastPathComponent)
                    try FileManager.default.copyItem(at: temp, to: destination)
                    saved[row.id] = destination; success += 1
                } catch {
                    errors.append("\(row.name)：\(error.localizedDescription)")
                    if Task.isCancelled { break }
                }
            }
            message = "已下載並驗證 \(success)/\(rows.count)；耳機原檔保留。" + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
        }
    }
    func cancel() { operation?.cancel() }
    func open(_ row: MediaFile) { if let url = saved[row.id] { NSWorkspace.shared.open(url) } }
}
