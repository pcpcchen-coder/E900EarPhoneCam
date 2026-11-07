import AppKit
import AVFoundation
import Foundation

struct AVMediaVerifier: MediaVerifier {
    func verify(_ file: URL, kind: String) async throws {
        if kind == "照片" {
            guard NSImage(contentsOf: file) != nil else { throw MediaError.message("圖片無法解碼") }
        } else if kind == "影片" || kind == "錄音" {
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: kind == "影片" ? .video : .audio)
            guard duration.seconds.isFinite, duration.seconds > 0, !tracks.isEmpty else { throw MediaError.message("媒體串流或時長無效") }
        }
    }
}

@MainActor final class MediaStore: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "mediaHost") ?? "192.168.169.1"
    @Published var files: [MediaFile] = []
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var message = "連上耳機 Wi-Fi 後讀取檔案清單"
    @Published var folder: URL?
    /// Keyed by listing + host + name so a same-named file from another host/listing never shows
    /// a stale local "open" button.
    @Published private(set) var saved: [MediaKey: URL] = [:]
    private var listing: (id: UUID, host: String)?
    private var operation: Task<Void, Never>?
    private let transport: MediaTransport
    private let verifier: MediaVerifier

    init(transport: MediaTransport = URLSessionTransport(), verifier: MediaVerifier = AVMediaVerifier()) {
        self.transport = transport; self.verifier = verifier
    }

    func savedURL(_ row: MediaFile) -> URL? {
        guard let listing else { return nil }
        return saved[MediaKey(listing: listing.id, host: listing.host, name: row.name)]
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "選擇下載資料夾"
        if panel.runModal() == .OK { folder = panel.url }
    }
    func list() {
        guard !busy else { return }
        let requestedHost = host
        busy = true; files = []; selected = []; listing = nil; message = "讀取中…"
        operation = Task {
            defer { busy = false }
            do {
                let url = try MediaAPI.url(host: requestedHost, name: "app/getfilelist")
                let temp = try await transport.fetch(url); defer { try? FileManager.default.removeItem(at: temp) }
                let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw MediaError.message("清單過大，已拒絕") }
                try Task.checkCancellation()
                let rows = try MediaAPI.parseList(Data(contentsOf: temp))
                guard host == requestedHost else { throw MediaError.message("讀取期間 IP 已變更，請重新讀取") }
                files = rows; listing = (UUID(), requestedHost)
                UserDefaults.standard.set(requestedHost, forKey: "mediaHost")
                message = "已讀取 \(files.count) 個檔案；size 是耳機原始欄位，單位尚未確認"
            } catch is CancellationError { message = "已取消讀取" }
            catch { message = "讀取失敗：\(error.localizedDescription)" }
        }
    }
    func download() {
        guard !busy, let folder else { message = "請先選擇下載資料夾"; return }
        guard let listing, listing.host == host else { message = "IP 已變更或尚未讀取，請重新讀取清單"; return }
        let rows = files.filter { selected.contains($0.id) }
        guard !rows.isEmpty else { message = "請先選擇檔案"; return }
        busy = true
        let downloader = MediaDownloader(transport: transport, verifier: verifier)
        operation = Task {
            defer { busy = false }
            let report = await downloader.download(rows, host: listing.host, to: folder) { [weak self] i, row in
                await MainActor.run { self?.message = "下載 \(i + 1)/\(rows.count)：\(row.name)" }
            }
            for (name, url) in report.saved { saved[MediaKey(listing: listing.id, host: listing.host, name: name)] = url }
            message = report.summary
        }
    }
    func cancel() { operation?.cancel() }
    func open(_ row: MediaFile) { if let url = savedURL(row) { NSWorkspace.shared.open(url) } }
}
