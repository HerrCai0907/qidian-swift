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
    /// 是否来自 `~/.qidian` 下的本地缓存。
    public let isFromCache: Bool

    public var id: Int64 { chapterId }
    public var text: String { paragraphs.joined(separator: "\n") }
}

/// 自动预缓存下一章的结果。
public enum ChapterPrefetchOutcome: Sendable, Equatable {
    /// 完整章节已写入本地缓存。
    case cached
    /// 下一章未购买（或未登录只能试读），按约定忽略。
    case ignoredNotPurchased
    /// 网络/解析等其它失败，不影响当前章阅读。
    case failed(String)
}

/// 组合 API + WebKit 兜底 + 本地缓存的一站式阅读会话。
///
/// 每成功下载一个完整章节，都会写入 `~/.qidian/<书名>/<chapterId>.json`；
/// 读到当前章后，会自动在后台尝试缓存下一章。下一章若是未购买的试读，
/// 直接忽略，不落盘、也不打扰当前阅读。
public final class QidianReadingSession: @unchecked Sendable {
    public let client: QidianClient
    public let cache: ChapterCache

    private var chapterCache: [Int64: LoadedChapter] = [:]
    private let lock = NSLock()

    /// 同一章的并发请求（阅读 + 自动预缓存）合并成一个任务。
    private var inFlight: [Int64: Task<LoadedChapter, Error>] = [:]

    private struct PrefetchRequest: Sendable {
        let bookId: Int64
        let chapterId: Int64
    }

    /// 同一时间只预取一章；用户快速翻页时以最新请求为准。
    private var pendingPrefetch: PrefetchRequest?
    private var prefetchTask: Task<Void, Never>?
    private var activePrefetchChapterId: Int64?
    private var ignoredPrefetches: Set<Int64> = []
    private var prefetchOutcomes: [Int64: ChapterPrefetchOutcome] = [:]

    /// VIP 密文是否允许回退到离屏 WebKit 解密。
    public var allowsWebDecryption = true

    /// 是否在读完当前章后自动尝试缓存下一章。
    public var prefetchNextChapter = true

    public init(cookies: CookieJar = CookieJar(),
                cookieFile: URL? = nil,
                cache: ChapterCache = ChapterCache()) {
        client = QidianClient(cookies: cookies)
        client.persistenceURL = cookieFile
        self.cache = cache
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
        try await chapter(bookId: bookId, chapterId: chapterId, prefetchNext: true)
    }

    /// - Parameter prefetchNext: 预取任务自身传 `false`，避免一章接一章无限往后爬。
    public func chapter(bookId: Int64,
                        chapterId: Int64,
                        prefetchNext: Bool) async throws -> LoadedChapter {
        let loaded = try await loadChapter(bookId: bookId, chapterId: chapterId)
        if prefetchNext {
            schedulePrefetchIfNeeded(after: loaded)
        }
        return loaded
    }

    // MARK: - Loading

    private func loadChapter(bookId: Int64, chapterId: Int64) async throws -> LoadedChapter {
        if let cached = cachedChapter(chapterId) { return cached }

        if let fromDisk = cache.load(bookId: bookId, chapterId: chapterId) {
            withLock { chapterCache[chapterId] = fromDisk }
            return fromDisk
        }

        let task = inFlightTask(bookId: bookId, chapterId: chapterId)
        return try await task.value
    }

    private func inFlightTask(bookId: Int64, chapterId: Int64) -> Task<LoadedChapter, Error> {
        withLock {
            if let existing = inFlight[chapterId] {
                return existing
            }
            let task = Task { [self] in
                defer { removeInFlight(chapterId) }
                return try await fetchChapter(bookId: bookId, chapterId: chapterId)
            }
            inFlight[chapterId] = task
            return task
        }
    }

    private func removeInFlight(_ chapterId: Int64) {
        withLock { inFlight[chapterId] = nil }
    }

    private func fetchChapter(bookId: Int64, chapterId: Int64) async throws -> LoadedChapter {
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
            isPreview: isPreview,
            isFromCache: false
        )

        // 只缓存完整章节：试读结果在登录/订阅后需要重新拉全文。
        if !isPreview {
            withLock { chapterCache[chapterId] = loaded }
            cache.save(loaded)
        }
        return loaded
    }

    /// 清空进程内缓存（磁盘上的 `~/.qidian/<书名>/` 会保留）。
    /// 登录态变化后调用，强制重新向服务端拉取当前章。
    public func clearCache() {
        withLock {
            chapterCache.removeAll()
            // 登录态变化后，之前“未购买”的下一章可能已经能读了。
            ignoredPrefetches.removeAll()
        }
    }

    private func cachedChapter(_ id: Int64) -> LoadedChapter? {
        withLock { chapterCache[id] }
    }

    // MARK: - Next-chapter prefetch

    /// 当前章已就绪后，在后台尝试把下一章也缓存下来。
    private func schedulePrefetchIfNeeded(after chapter: LoadedChapter) {
        guard prefetchNextChapter,
              let nextId = chapter.nextId,
              nextId > 0,
              nextId != chapter.chapterId else { return }
        schedulePrefetch(bookId: chapter.bookId, chapterId: nextId)
    }

    private func schedulePrefetch(bookId: Int64, chapterId: Int64) {
        // 内存或磁盘已有该章时无需再请求。
        if cachedChapter(chapterId) != nil || cache.isCached(bookId: bookId, chapterId: chapterId) {
            return
        }

        withLock {
            // 用户正在打开这一章时，复用 inFlight，不再单独预取。
            if inFlight[chapterId] != nil
                || ignoredPrefetches.contains(chapterId)
                || activePrefetchChapterId == chapterId
                || pendingPrefetch?.chapterId == chapterId {
                return
            }

            pendingPrefetch = PrefetchRequest(bookId: bookId, chapterId: chapterId)
            if prefetchTask == nil {
                prefetchTask = Task { await self.drainPrefetchQueue() }
            }
        }
    }

    /// 串行执行预取；新请求会覆盖尚未开始的旧请求（只预取“下一章”，不做整书爬取）。
    private func drainPrefetchQueue() async {
        while true {
            let request: PrefetchRequest? = withLock {
                guard let request = pendingPrefetch else {
                    prefetchTask = nil
                    activePrefetchChapterId = nil
                    return nil
                }
                pendingPrefetch = nil
                activePrefetchChapterId = request.chapterId
                return request
            }
            guard let request else { return }

            let outcome: ChapterPrefetchOutcome
            do {
                let chapter = try await chapter(bookId: request.bookId,
                                                chapterId: request.chapterId,
                                                prefetchNext: false)
                if chapter.isPreview {
                    outcome = .ignoredNotPurchased
                } else if cache.isCached(bookId: request.bookId, chapterId: request.chapterId) {
                    outcome = .cached
                } else {
                    outcome = .failed("写入本地缓存失败")
                }
            } catch {
                if let qidianError = error as? QidianError,
                   case .notPurchased = qidianError {
                    outcome = .ignoredNotPurchased
                } else {
                    outcome = .failed(error.localizedDescription)
                }
            }

            withLock {
                prefetchOutcomes[request.chapterId] = outcome
                if outcome == .ignoredNotPurchased {
                    // 未购买/试读：按约定忽略，之后不再反复请求。
                    ignoredPrefetches.insert(request.chapterId)
                }
            }
        }
    }

    /// 等待后台预取结束。CLI 在退出前调用，确保缓存已经落盘；GUI 不需要。
    public func waitForPrefetch() async {
        while true {
            let state: (Task<Void, Never>?, PrefetchRequest?) = withLock {
                (prefetchTask, pendingPrefetch)
            }

            if let task = state.0 {
                await task.value
                continue
            }
            if state.1 == nil { return }
            await Task.yield()
        }
    }

    /// 查询某一章的自动预取结果（没有预取过则为 nil）。
    public func prefetchOutcome(chapterId: Int64) -> ChapterPrefetchOutcome? {
        withLock { prefetchOutcomes[chapterId] }
    }

    /// 缓存文件路径，便于 CLI 提示用户。
    public func cachedFileURL(bookId: Int64, chapterId: Int64) -> URL? {
        cache.fileURL(bookId: bookId, chapterId: chapterId)
    }

    /// `NSLock` 不能在 async 函数里直接 lock/unlock（Swift 6 会报错），
    /// 统一用这个同步作用域包一层。
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
