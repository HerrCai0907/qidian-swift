import Foundation

/// 阅读器直接消费的章节模型。
public struct LoadedChapter: Sendable, Identifiable {
    public let chapterId: Int64
    public let bookId: Int64
    public let bookName: String
    public let authorName: String
    public let title: String
    public let volumeName: String?
    public let paragraphs: [String]
    public let prevId: Int64?
    public let nextId: Int64?
    public let prevName: String?
    public let nextName: String?
    public let wordsCount: Int
    public let authorSay: String?
    /// 正文是否由 WebKit 兜底解出（VIP 密文章节）。
    public let decryptedByWeb: Bool
    /// 未订阅时的试读片段。
    public let isPreview: Bool

    public var id: Int64 { chapterId }
    public var text: String { paragraphs.joined(separator: "\n") }
}

/// 组合 API + WebKit 兜底的一站式阅读会话。
public final class QidianReadingSession {
    public let client: QidianClient

    private var chapterCache: [Int64: LoadedChapter] = [:]
    private let lock = NSLock()

    /// VIP 密文是否允许回退到离屏 WebKit 解密。
    public var allowsWebDecryption = true

    public init(cookies: CookieJar = CookieJar(), cookieFile: URL? = nil) {
        client = QidianClient(cookies: cookies)
        client.persistenceURL = cookieFile
    }

    public convenience init(cookieFile: URL = CookieJar.defaultURL) {
        self.init(cookies: (try? CookieJar.load(from: cookieFile)) ?? CookieJar(),
                  cookieFile: cookieFile)
    }

    public var isLoggedIn: Bool { client.isLoggedIn }

    public var cookies: CookieJar { client.cookies }

    public func open(_ ref: ChapterRef) async throws -> LoadedChapter {
        try await chapter(bookId: ref.bookId, chapterId: ref.chapterId)
    }

    public func chapter(bookId: Int64, chapterId: Int64) async throws -> LoadedChapter {
        if let cached = cachedChapter(chapterId) { return cached }

        let data = try await client.chapter(bookId: bookId, chapterId: chapterId)
        let info = data.chapterInfo
        var content = client.content(of: data)
        var usedWeb = false

        if content.isEncrypted {
            guard allowsWebDecryption else {
                throw info.isBuy == 0 ? QidianError.notPurchased(price: info.price)
                                      : QidianError.encryptedContent
            }
            #if canImport(WebKit)
            let paragraphs = try await WebChapterFetcher.shared.fetch(
                bookId: bookId,
                chapterId: chapterId,
                cookies: client.cookies
            )
            content = ChapterContent(paragraphs: paragraphs, isEncrypted: false)
            usedWeb = true
            #else
            throw QidianError.webKitUnavailable
            #endif
        }

        let isPreview = info.isBuy == 0 && (info.vipStatus ?? 0) == 1
        let loaded = LoadedChapter(
            chapterId: info.chapterId,
            bookId: bookId,
            bookName: data.bookInfo?.bookName ?? "",
            authorName: data.bookInfo?.authorName ?? "",
            title: info.chapterName,
            volumeName: info.volumeName,
            paragraphs: content.paragraphs,
            prevId: info.prev,
            nextId: info.next,
            prevName: info.prevName,
            nextName: info.nextName,
            wordsCount: info.wordsCount,
            authorSay: info.authorSay?.trimmingCharacters(in: .whitespacesAndNewlines),
            decryptedByWeb: usedWeb,
            isPreview: isPreview
        )

        // 试读结果不缓存：登录/订阅后需要重新拉全文。
        if !isPreview {
            lock.lock(); chapterCache[chapterId] = loaded; lock.unlock()
        }
        return loaded
    }

    public func clearCache() {
        lock.lock(); chapterCache.removeAll(); lock.unlock()
    }

    private func cachedChapter(_ id: Int64) -> LoadedChapter? {
        lock.lock(); defer { lock.unlock() }
        return chapterCache[id]
    }
}
