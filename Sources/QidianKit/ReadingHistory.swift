import Foundation

/// 一本书的最近阅读进度。
public struct ReadingHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let bookId: Int64
    public let chapterId: Int64
    public let bookName: String
    public let chapterTitle: String
    /// 相对正文起点的字符偏移；负数表示还停留在标题/简介等正文前内容。
    public let anchor: Int
    public let updatedAt: Date

    public var id: String { "\(bookId)" }

    public init(bookId: Int64,
                chapterId: Int64,
                bookName: String,
                chapterTitle: String,
                anchor: Int,
                updatedAt: Date = Date()) {
        self.bookId = bookId
        self.chapterId = chapterId
        self.bookName = bookName
        self.chapterTitle = chapterTitle
        self.anchor = anchor
        self.updatedAt = updatedAt
    }
}

/// 阅读进度持久化：`~/.qidian/progress.json`（每本书保留最近一条，最多 50 本）。
public final class ReadingHistoryStore: @unchecked Sendable {
    public static let maxEntries = 50
    public static let fileName = "progress.json"

    /// 默认与缓存同目录，便于测试时用 `QIDIAN_CACHE` 整体隔离；
    /// 也可用 `QIDIAN_PROGRESS` 单独指定文件路径。
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["QIDIAN_PROGRESS"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return ChapterCache.defaultRootURL.appendingPathComponent(fileName)
    }

    public let url: URL
    private let lock = NSLock()
    private var storedEntries: [ReadingHistoryEntry]

    public init(url: URL = ReadingHistoryStore.defaultURL) {
        self.url = url.standardizedFileURL
        self.storedEntries = Self.load(from: self.url)
    }

    public var entries: [ReadingHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    public var lastEntry: ReadingHistoryEntry? {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries.first
    }

    public func entry(forBookId bookId: Int64) -> ReadingHistoryEntry? {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries.first { $0.bookId == bookId }
    }

    /// 记录/更新一本书的阅读位置。同一个位置重复写入会被忽略。
    @discardableResult
    public func record(bookId: Int64,
                       chapterId: Int64,
                       bookName: String,
                       chapterTitle: String,
                       anchor: Int,
                       at date: Date = Date()) -> Bool {
        guard bookId > 0, chapterId > 0 else { return false }
        let name = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        if let first = storedEntries.first,
           first.bookId == bookId,
           first.chapterId == chapterId,
           first.anchor == anchor,
           first.bookName == name,
           first.chapterTitle == title {
            lock.unlock()
            return false
        }

        storedEntries.removeAll { $0.bookId == bookId }
        storedEntries.insert(
            ReadingHistoryEntry(bookId: bookId,
                                chapterId: chapterId,
                                bookName: name,
                                chapterTitle: title,
                                anchor: anchor,
                                updatedAt: date),
            at: 0
        )
        if storedEntries.count > Self.maxEntries {
            storedEntries.removeLast(storedEntries.count - Self.maxEntries)
        }
        let snapshot = storedEntries
        lock.unlock()

        Self.save(snapshot, to: url)
        return true
    }

    public func removeAll() {
        lock.lock()
        storedEntries.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        let version: Int
        let entries: [ReadingHistoryEntry]
    }

    private static func load(from url: URL) -> [ReadingHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return [] }
        // 文件本身按“最近在前”写入，保持顺序即可；避免同一秒的时间戳排序不稳定。
        let valid = payload.entries.filter { $0.bookId > 0 && $0.chapterId > 0 }
        return Array(valid.prefix(maxEntries))
    }

    private static func save(_ entries: [ReadingHistoryEntry], to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Payload(version: 1, entries: entries))
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            // 进度写入失败不应影响阅读。
        }
    }
}
