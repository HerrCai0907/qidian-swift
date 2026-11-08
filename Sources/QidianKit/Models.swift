import Foundation

// MARK: - Envelope

/// 起点 `webcommon` 接口统一返回 `{ code, data, msg, serverTime }`，`code == 0` 表示成功。
public struct APIEnvelope<Payload: Decodable>: Decodable {
    public let code: Int
    public let msg: String?
    public let data: Payload?

    public var isOK: Bool { code == 0 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? c.decode(Int.self, forKey: .code)) ?? -1
        msg = try? c.decode(String.self, forKey: .msg)
        data = try? c.decode(Payload.self, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey { case code, msg, data }
}

// MARK: - Book

public struct BookInfo: Decodable, Sendable, Hashable {
    public let bookId: Int64
    public let bookName: String
    public let authorName: String
    public let wordsCnt: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookId = (try? c.decode(Int64.self, forKey: .bookId)) ?? 0
        bookName = (try? c.decode(String.self, forKey: .bookName)) ?? ""
        authorName = (try? c.decode(String.self, forKey: .authorName)) ?? ""
        wordsCnt = try? c.decode(Int.self, forKey: .wordsCnt)
    }

    enum CodingKeys: String, CodingKey { case bookId, bookName, authorName, wordsCnt }
}

// MARK: - Chapter

public struct ChapterData: Decodable, Sendable {
    public let isLogin: Int
    public let bookInfo: BookInfo?
    public let chapterInfo: ChapterInfo

    public var loggedIn: Bool { isLogin == 1 }

    enum CodingKeys: String, CodingKey { case isLogin, bookInfo, chapterInfo }
}

public struct ChapterInfo: Decodable, Sendable {
    public let chapterId: Int64
    public let chapterName: String
    /// 免费章节为 `<p>` 段落 HTML；已订阅的 VIP 章节为 Base64 密文（需 Fock 解密）。
    public let content: String
    /// Fock 密钥池脚本：`window.onkeyfocus("…", version)` 的 Base64。
    public let fkp: String?
    /// 1：当前账号已购买本章。
    public let isBuy: Int
    public let price: Int
    public let wordsCount: Int
    public let updateTime: String?
    public let prev: Int64?
    public let next: Int64?
    public let extra: ChapterExtra?
    public let authorSay: String?
    public let vipStatus: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterId = try c.decode(Int64.self, forKey: .chapterId)
        chapterName = (try? c.decode(String.self, forKey: .chapterName)) ?? ""
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        fkp = try? c.decode(String.self, forKey: .fkp)
        isBuy = (try? c.decode(Int.self, forKey: .isBuy)) ?? 0
        price = (try? c.decode(Int.self, forKey: .price)) ?? 0
        wordsCount = (try? c.decode(Int.self, forKey: .wordsCount)) ?? 0
        updateTime = try? c.decode(String.self, forKey: .updateTime)
        prev = try? c.decode(Int64.self, forKey: .prev)
        next = try? c.decode(Int64.self, forKey: .next)
        extra = try? c.decode(ChapterExtra.self, forKey: .extra)
        authorSay = try? c.decode(String.self, forKey: .authorSay)
        vipStatus = try? c.decode(Int.self, forKey: .vipStatus)
    }

    enum CodingKeys: String, CodingKey {
        case chapterId, chapterName, content, fkp, isBuy, price, wordsCount, updateTime
        case prev, next, extra, authorSay, vipStatus
    }

    public var volumeName: String? { extra?.volumeName }
    public var prevName: String? { extra?.prevName }
    public var nextName: String? { extra?.nextName }
}

public struct ChapterExtra: Decodable, Sendable {
    public let volumeName: String?
    public let prevName: String?
    public let nextName: String?
    public let prevVipStatus: Int?
    public let nextVipStatus: Int?
}

// MARK: - Catalog

/// 全书目录：`GET /webcommon/book/mCategory?bookId=…`。
///
/// 目录按卷分组，一次返回整本书（1000+ 章也只有一个请求）。
public struct BookCatalog: Decodable, Sendable, Equatable, Identifiable {
    public let bookId: Int64
    public let bookName: String
    public let chapterTotalCnt: Int
    public let bookStatus: String?
    public let volumes: [CatalogVolume]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookId = (try? c.decode(Int64.self, forKey: .bookId)) ?? 0
        bookName = (try? c.decode(String.self, forKey: .bookName)) ?? ""
        chapterTotalCnt = (try? c.decode(Int.self, forKey: .chapterTotalCnt)) ?? 0
        bookStatus = try? c.decode(String.self, forKey: .bookStatus)
        volumes = (try? c.decode([CatalogVolume].self, forKey: .volumes)) ?? []
    }

    /// 供测试/本地构造使用。
    public init(bookId: Int64,
                bookName: String,
                chapterTotalCnt: Int = 0,
                bookStatus: String? = nil,
                volumes: [CatalogVolume]) {
        self.bookId = bookId
        self.bookName = bookName
        self.chapterTotalCnt = chapterTotalCnt
        self.bookStatus = bookStatus
        self.volumes = volumes
    }

    enum CodingKeys: String, CodingKey {
        case bookId, bookName, chapterTotalCnt, bookStatus
        case volumes = "vs"
    }

    public var id: Int64 { bookId }

    /// 按目录顺序展开的全部章节。
    public var allChapters: [CatalogChapter] { volumes.flatMap(\.chapters) }

    public var chapterCount: Int {
        allChapters.isEmpty ? chapterTotalCnt : allChapters.count
    }

    public var isEmpty: Bool { allChapters.isEmpty }

    public func chapter(withId chapterId: Int64) -> CatalogChapter? {
        allChapters.first { $0.chapterId == chapterId }
    }

    public func volume(containing chapterId: Int64) -> CatalogVolume? {
        volumes.first { $0.chapters.contains { $0.chapterId == chapterId } }
    }

    /// 按章节名筛选；空关键词返回全书章节。
    ///
    /// 接口里的 `uuid` 实测并不严格按目录顺序递增，所以不能拿它当“第几章”。
    public func chapters(matching query: String) -> [CatalogChapter] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return allChapters }
        return allChapters.filter { $0.displayTitle.localizedCaseInsensitiveContains(keyword) }
    }
}

public struct CatalogVolume: Decodable, Sendable, Equatable, Identifiable {
    public let volumeId: Int64
    public let name: String
    /// 接口声明的本章节数（`cCnt`）。
    public let declaredChapterCount: Int
    public let wordCount: Int
    public let chapters: [CatalogChapter]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeId = (try? c.decode(Int64.self, forKey: .volumeId)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        declaredChapterCount = (try? c.decode(Int.self, forKey: .declaredChapterCount)) ?? 0
        wordCount = (try? c.decode(Int.self, forKey: .wordCount)) ?? 0
        chapters = (try? c.decode([CatalogChapter].self, forKey: .chapters)) ?? []
    }

    public init(volumeId: Int64,
                name: String,
                declaredChapterCount: Int = 0,
                wordCount: Int = 0,
                chapters: [CatalogChapter]) {
        self.volumeId = volumeId
        self.name = name
        self.declaredChapterCount = declaredChapterCount
        self.wordCount = wordCount
        self.chapters = chapters
    }

    enum CodingKeys: String, CodingKey {
        case volumeId = "vId"
        case name = "vN"
        case declaredChapterCount = "cCnt"
        case wordCount = "wC"
        case chapters = "cs"
    }

    public var id: Int64 { volumeId }

    public var chapterCount: Int {
        chapters.isEmpty ? declaredChapterCount : chapters.count
    }

    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "正文" : name
    }
}

public struct CatalogChapter: Decodable, Sendable, Equatable, Identifiable {
    public let chapterId: Int64
    public let title: String
    public let wordCount: Int
    public let updateTime: String?
    /// `sS == 1` 为收费章节；限免活动期间仍为 1，能否读全文以章节接口为准。
    public let isPaid: Bool
    /// 接口返回的章节唯一序号（`uuid`）。实测不保证按目录顺序递增，仅作原始字段保留。
    public let uuid: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterId = (try? c.decode(Int64.self, forKey: .chapterId)) ?? 0
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        wordCount = (try? c.decode(Int.self, forKey: .wordCount)) ?? 0
        updateTime = try? c.decode(String.self, forKey: .updateTime)
        isPaid = ((try? c.decode(Int.self, forKey: .paid)) ?? 0) == 1
        uuid = (try? c.decode(Int.self, forKey: .uuid)) ?? 0
    }

    public init(chapterId: Int64,
                title: String,
                wordCount: Int = 0,
                updateTime: String? = nil,
                isPaid: Bool = false,
                uuid: Int = 0) {
        self.chapterId = chapterId
        self.title = title
        self.wordCount = wordCount
        self.updateTime = updateTime
        self.isPaid = isPaid
        self.uuid = uuid
    }

    enum CodingKeys: String, CodingKey {
        case chapterId = "id"
        case title = "cN"
        case wordCount = "cnt"
        case updateTime = "uT"
        case paid = "sS"
        case uuid
    }

    public var id: Int64 { chapterId }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "章节 \(chapterId)" : trimmed
    }
}

// MARK: - Book reference

/// 书籍页链接或纯 `bookId`，用于在目录里打开任意一本书：
/// - `https://www.qidian.com/book/1037095853/`
/// - `https://m.qidian.com/book/1037095853/?source=pc_jump`
/// - `1037095853`
public struct BookRef: Sendable, Hashable {
    public let bookId: Int64

    public init(bookId: Int64) {
        self.bookId = bookId
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = "book/(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(match.range(at: 1), in: trimmed),
           let bookId = Int64(trimmed[range]), bookId > 0 {
            self.init(bookId: bookId)
            return
        }

        let numbers = trimmed.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
        guard numbers.count == 1, let bookId = numbers.first, bookId > 0 else { return nil }
        self.init(bookId: bookId)
    }
}

// MARK: - Chapter reference

/// 支持三种输入：
/// - `https://www.qidian.com/chapter/1037095853/801714441/`
/// - `https://m.qidian.com/chapter/1037095853/801714441/?source=...`
/// - `1037095853 801714441` / `1037095853/801714441`
public struct ChapterRef: Sendable, Hashable, Identifiable {
    public let bookId: Int64
    public let chapterId: Int64

    public var id: String { "\(bookId)-\(chapterId)" }

    public init(bookId: Int64, chapterId: Int64) {
        self.bookId = bookId
        self.chapterId = chapterId
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = "chapter/(\\d+)/(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let bookRange = Range(match.range(at: 1), in: trimmed),
           let chapterRange = Range(match.range(at: 2), in: trimmed),
           let bookId = Int64(trimmed[bookRange]),
           let chapterId = Int64(trimmed[chapterRange]) {
            self.init(bookId: bookId, chapterId: chapterId)
            return
        }

        let numbers = trimmed.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
        guard numbers.count == 2 else { return nil }
        self.init(bookId: numbers[0], chapterId: numbers[1])
    }
}

// MARK: - Decoded content

public struct ChapterContent: Sendable, Equatable {
    public let paragraphs: [String]
    /// true 表示接口返回的是密文，必须交给 Fock 解密（本项目用 WebKit 兜底）。
    public let isEncrypted: Bool

    public init(paragraphs: [String], isEncrypted: Bool) {
        self.paragraphs = paragraphs
        self.isEncrypted = isEncrypted
    }

    public var text: String { paragraphs.joined(separator: "\n") }

    public static let empty = ChapterContent(paragraphs: [], isEncrypted: false)
}

// MARK: - Errors

public enum QidianError: LocalizedError, Sendable {
    case http(Int)
    case api(code: Int, message: String)
    case riskControl
    case notLoggedIn
    case notPurchased(price: Int)
    case encryptedContent
    case parse(String)
    case timeout
    case webKitUnavailable

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .api(let code, let message): return "接口错误 \(code): \(message)"
        case .riskControl: return "触发起点风控（WAF / 验证码），请稍后再试"
        case .notLoggedIn: return "未登录：请先登录"
        case .notPurchased(let price): return "本章未订阅（\(price) 起点币）"
        case .encryptedContent: return "正文为密文，需要 WebKit 解密"
        case .parse(let why): return "解析失败: \(why)"
        case .timeout: return "加载超时"
        case .webKitUnavailable: return "当前平台不支持 WebKit"
        }
    }
}
