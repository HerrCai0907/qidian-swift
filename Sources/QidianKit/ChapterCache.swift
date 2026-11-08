import Foundation

/// 章节本地缓存。
///
/// 布局（按书名分目录，所有内容都在 `~/.qidian` 下）：
///
/// ```
/// ~/.qidian/
/// ├── cookies.json
/// └── 牧者密续/
///     ├── _book.json          # bookId / 书名 / 作者
///     ├── 753919666.json      # 每章一个 JSON，含正文段落与上下章信息
///     └── 801714441.json
/// ```
///
/// 只缓存完整章节：试读片段、空正文都不会落盘。
/// 文件夹名取自 `bookInfo.bookName`，会替换文件系统非法字符；
/// 同名不同书时追加 `-<bookId>`，避免串书。
public final class ChapterCache: @unchecked Sendable {
    /// 每本书目录下的元数据文件。
    public static let metadataFileName = "_book.json"

    /// 默认根目录：`~/.qidian`，可用环境变量 `QIDIAN_CACHE` 覆盖。
    public static var defaultRootURL: URL {
        if let path = ProcessInfo.processInfo.environment["QIDIAN_CACHE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qidian", isDirectory: true)
    }

    public let root: URL

    private let fileManager = FileManager.default
    private let lock = NSLock()
    /// bookId → 书目录。首次使用时扫描磁盘建立，之后随写入更新。
    private var bookDirectories: [Int64: URL] = [:]
    private var didScan = false

    public init(root: URL = ChapterCache.defaultRootURL) {
        self.root = root.standardizedFileURL
        try? fileManager.createDirectory(at: self.root,
                                         withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
    }

    // MARK: - Read

    /// 读取某章缓存；不存在或内容损坏时返回 nil（调用方应回退到网络）。
    public func load(bookId: Int64, chapterId: Int64) -> LoadedChapter? {
        guard let url = fileURL(bookId: bookId, chapterId: chapterId),
              let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(Record.self, from: data),
              record.bookId == bookId,
              record.chapterId == chapterId,
              !record.paragraphs.isEmpty else { return nil }
        return record.loadedChapter
    }

    public func isCached(bookId: Int64, chapterId: Int64) -> Bool {
        guard let url = fileURL(bookId: bookId, chapterId: chapterId) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    /// 章节缓存文件的绝对路径；书目录不存在时返回 nil。
    public func fileURL(bookId: Int64, chapterId: Int64) -> URL? {
        lock.lock()
        let directory = directoryLocked(forBookId: bookId)
        lock.unlock()
        return directory?.appendingPathComponent("\(chapterId).json")
    }

    /// 某本书已经落盘的章节 id，按从小到大排序。
    public func cachedChapterIds(bookId: Int64) -> [Int64] {
        lock.lock()
        let directory = directoryLocked(forBookId: bookId)
        lock.unlock()
        guard let directory,
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.compactMap { name -> Int64? in
            guard name.hasSuffix(".json"),
                  !name.hasPrefix("_"),
                  let id = Int64(name.dropLast(5)) else { return nil }
            return id
        }.sorted()
    }

    // MARK: - Write

    /// 把完整章节写入 `<root>/<书名>/<chapterId>.json`。
    ///
    /// - Returns: 写入的文件 URL；试读、空正文或写入失败时返回 nil。
    @discardableResult
    public func save(_ chapter: LoadedChapter) -> URL? {
        // 试读片段不是完整正文，缓存后会导致以后一直读到半章。
        guard !chapter.isPreview, !chapter.paragraphs.isEmpty else { return nil }

        lock.lock()
        guard let directory = ensureDirectoryLocked(bookId: chapter.bookId,
                                                    bookName: chapter.bookName,
                                                    authorName: chapter.authorName) else {
            lock.unlock()
            return nil
        }
        let url = directory.appendingPathComponent("\(chapter.chapterId).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let record = Record(chapter: chapter)
        do {
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
            lock.unlock()
            return url
        } catch {
            lock.unlock()
            return nil
        }
    }

    // MARK: - Directory layout

    private func directoryLocked(forBookId bookId: Int64) -> URL? {
        scanIfNeededLocked()
        return bookDirectories[bookId]
    }

    private func ensureDirectoryLocked(bookId: Int64, bookName: String, authorName: String) -> URL? {
        scanIfNeededLocked()
        if let existing = bookDirectories[bookId] {
            try? writeMetadataIfNeeded(in: existing,
                                       bookId: bookId,
                                       bookName: bookName,
                                       authorName: authorName)
            return existing
        }

        let base = Self.sanitizedFolderName(bookName, bookId: bookId)
        var candidate = root.appendingPathComponent(base, isDirectory: true)

        // 同名目录可能属于另一本书。带 bookId 的后缀保证不串书。
        if fileManager.fileExists(atPath: candidate.path) {
            if let meta = readMetadata(in: candidate), meta.bookId == bookId {
                bookDirectories[bookId] = candidate
                try? writeMetadataIfNeeded(in: candidate,
                                           bookId: bookId,
                                           bookName: bookName,
                                           authorName: authorName)
                return candidate
            }
            candidate = root.appendingPathComponent("\(base)-\(bookId)", isDirectory: true)
        }

        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            if let meta = readMetadata(in: candidate), meta.bookId == bookId {
                bookDirectories[bookId] = candidate
                return candidate
            }
            candidate = root.appendingPathComponent("\(base)-\(bookId)-\(suffix)", isDirectory: true)
            suffix += 1
            if suffix > 100 { return nil }
        }

        do {
            try fileManager.createDirectory(at: candidate,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let meta = BookMeta(bookId: bookId,
                                bookName: bookName,
                                authorName: authorName,
                                updatedAt: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meta).write(to: candidate.appendingPathComponent(Self.metadataFileName),
                                           options: .atomic)
            bookDirectories[bookId] = candidate
            return candidate
        } catch {
            return nil
        }
    }

    private func scanIfNeededLocked() {
        guard !didScan else { return }
        didScan = true

        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let children = try? fileManager.contentsOfDirectory(at: root,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else {
            return
        }
        for child in children {
            guard (try? child.resourceValues(forKeys: Set(keys)).isDirectory) == true,
                  let meta = readMetadata(in: child),
                  meta.bookId > 0 else { continue }
            bookDirectories[meta.bookId] = child
        }
    }

    private func readMetadata(in directory: URL) -> BookMeta? {
        let url = directory.appendingPathComponent(Self.metadataFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BookMeta.self, from: data)
    }

    private func writeMetadataIfNeeded(in directory: URL,
                                       bookId: Int64,
                                       bookName: String,
                                       authorName: String) throws {
        if let existing = readMetadata(in: directory),
           existing.bookId == bookId,
           existing.bookName == bookName,
           existing.authorName == authorName {
            return
        }
        let meta = BookMeta(bookId: bookId,
                            bookName: bookName,
                            authorName: authorName,
                            updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: directory.appendingPathComponent(Self.metadataFileName),
                                       options: .atomic)
    }

    /// 把书名变成安全的目录名：非法字符替换为 `_`，去掉首尾点/空格，限制长度。
    static func sanitizedFolderName(_ name: String, bookId: Int64) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var safe = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || forbidden.contains(scalar) {
                safe.append("_")
            } else {
                safe.unicodeScalars.append(scalar)
            }
        }
        safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if safe.isEmpty || safe == "." || safe == ".." {
            safe = "book-\(bookId)"
        }
        if safe.hasPrefix(".") { safe = "_" + safe }
        if safe.count > 60 { safe = String(safe.prefix(60)) }
        return safe
    }
}

// MARK: - On-disk records

public extension ChapterCache {
    /// `<书目录>/_book.json`。
    struct BookMeta: Codable, Sendable {
        public let bookId: Int64
        public let bookName: String
        public let authorName: String
        public let updatedAt: Date

        public init(bookId: Int64, bookName: String, authorName: String, updatedAt: Date) {
            self.bookId = bookId
            self.bookName = bookName
            self.authorName = authorName
            self.updatedAt = updatedAt
        }
    }

    /// 每章一个 JSON。字段独立于 `LoadedChapter`，方便以后升级格式。
    struct Record: Codable, Sendable {
        public let schemaVersion: Int
        public let bookId: Int64
        public let bookName: String
        public let authorName: String
        public let chapterId: Int64
        public let title: String
        public let volumeName: String?
        public let paragraphs: [String]
        public let prevId: Int64?
        public let nextId: Int64?
        public let prevName: String?
        public let nextName: String?
        public let wordsCount: Int
        public let authorSay: String?
        public let savedAt: Date

        public init(chapter: LoadedChapter, savedAt: Date = Date()) {
            self.schemaVersion = 1
            self.bookId = chapter.bookId
            self.bookName = chapter.bookName
            self.authorName = chapter.authorName
            self.chapterId = chapter.chapterId
            self.title = chapter.title
            self.volumeName = chapter.volumeName
            self.paragraphs = chapter.paragraphs
            self.prevId = chapter.prevId
            self.nextId = chapter.nextId
            self.prevName = chapter.prevName
            self.nextName = chapter.nextName
            self.wordsCount = chapter.wordsCount
            self.authorSay = chapter.authorSay
            self.savedAt = savedAt
        }

        public var loadedChapter: LoadedChapter {
            LoadedChapter(
                chapterId: chapterId,
                bookId: bookId,
                bookName: bookName,
                authorName: authorName,
                title: title,
                volumeName: volumeName,
                paragraphs: paragraphs,
                prevId: prevId,
                nextId: nextId,
                prevName: prevName,
                nextName: nextName,
                wordsCount: wordsCount,
                authorSay: authorSay,
                decryptedByWeb: false,
                isPreview: false,
                isFromCache: true
            )
        }
    }
}
