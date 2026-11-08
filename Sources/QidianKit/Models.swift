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
