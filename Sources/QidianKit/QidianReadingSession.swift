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

/// 组合 API + WebKit 兜底 + 本地缓存的一站式阅读会话。
///
/// 每成功下载一个完整章节，都会写入 `~/.qidian/<书名>/<chapterId>.json`；
/// 读到当前章后，会自动在后台尝试缓存下一章。下一章若是未购买的试读，
/// 直接忽略，不落盘、也不打扰当前阅读。
///
/// 打开一本书后还可以启动「整本后台下载」：按目录顺序（当前章往后、绕回开头）
/// 逐章补齐，每两章之间等待 1 分钟 + 1 分钟 × 随机数，已缓存的章节直接跳过。
public final class QidianReadingSession: @unchecked Sendable {
    public let client: QidianClient
    public let cache: ChapterCache

    private var chapterCache: [Int64: LoadedChapter] = [:]
    /// 目录只缓存一个进程，切换书籍再切回来时不用重复请求。
    private var catalogCache: [Int64: BookCatalog] = [:]
    private let lock = NSLock()

    /// 同一章的并发请求（阅读 + 自动预缓存）合并成一个任务。
    private var inFlight: [Int64: Task<LoadedChapter, Error>] = [:]
    /// 同一本书目录的并发请求合并成一个任务。
    private var catalogInFlight: [Int64: Task<BookCatalog, Error>] = [:]

    private struct PrefetchRequest: Sendable {
        let bookId: Int64
        let chapterId: Int64
    }

    /// 同一时间只预取一章；用户快速翻页时以最新请求为准。
    private var pendingPrefetch: PrefetchRequest?
    private var prefetchTask: Task<Void, Never>?
    private var activePrefetchChapterId: Int64?
    private var ignoredPrefetches: Set<Int64> = []

    // MARK: - Whole-book background download state

    /// 同一时间只下载一本书；打开新书时旧队列会被取消。
    private var wholeBookTask: Task<Void, Never>?
    /// 任务代次：取消/重启后，旧任务即使还在跑也不能再写状态。
    private var wholeBookGeneration = 0
    private var wholeBookBookId: Int64?
    private var wholeBookStatus: WholeBookDownloadStatus?
    /// 本次进程内确认读不了的章节（未购买/试读），不再重复请求。
    private var wholeBookUnavailable: [Int64: Set<Int64>] = [:]
    private var wholeBookPaused = false

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

    // MARK: - Catalog

    /// 读取某本书的完整目录。默认复用进程内缓存；`forceRefresh` 用于手动刷新。
    public func catalog(bookId: Int64, forceRefresh: Bool = false) async throws -> BookCatalog {
        if !forceRefresh, let cached = withLock({ catalogCache[bookId] }) {
            return cached
        }

        let task = withLock { () -> Task<BookCatalog, Error> in
            if !forceRefresh, let existing = catalogInFlight[bookId] {
                return existing
            }
            let task = Task { [self] in
                defer { withLock { catalogInFlight[bookId] = nil } }
                return try await client.catalog(bookId: bookId)
            }
            catalogInFlight[bookId] = task
            return task
        }

        let catalog = try await task.value
        withLock { catalogCache[bookId] = catalog }
        return catalog
    }

    /// 清空进程内缓存（磁盘上的 `~/.qidian/<书名>/` 会保留）。
    /// 登录态变化后调用，强制重新向服务端拉取当前章。
    public func clearCache() {
        let hadWholeBookStatus: Bool = withLock {
            chapterCache.removeAll()
            catalogCache.removeAll()
            // 登录态变化后，之前“未购买”的下一章可能已经能读了。
            ignoredPrefetches.removeAll()
            // 整本下载也要重算：之前跳过的未购买章节现在可能可读。
            wholeBookUnavailable.removeAll()
            wholeBookGeneration &+= 1
            wholeBookTask?.cancel()
            wholeBookTask = nil
            wholeBookBookId = nil
            wholeBookPaused = false
            let hadStatus = wholeBookStatus != nil
            wholeBookStatus = nil
            return hadStatus
        }
        if hadWholeBookStatus { onWholeBookDownloadUpdate?(nil) }
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

            do {
                let chapter = try await chapter(bookId: request.bookId,
                                                chapterId: request.chapterId,
                                                prefetchNext: false)
                if chapter.isPreview {
                    markPrefetchIgnored(request.chapterId)
                }
            } catch {
                // 未购买/试读：按约定忽略，之后不再反复请求。
                if let qidianError = error as? QidianError,
                   case .notPurchased = qidianError {
                    markPrefetchIgnored(request.chapterId)
                }
                // 网络/解析等失败只影响这次后台预取，不打扰当前阅读。
            }
        }
    }

    private func markPrefetchIgnored(_ chapterId: Int64) {
        withLock { ignoredPrefetches.insert(chapterId) }
    }

    // MARK: - Whole-book background download

    /// 整本下载状态变化回调。可能在后台线程触发，UI 需要自己切回主线程。
    public var onWholeBookDownloadUpdate: (@Sendable (WholeBookDownloadStatus?) -> Void)?

    public var wholeBookDownloadStatus: WholeBookDownloadStatus? {
        withLock { wholeBookStatus }
    }

    /// 打开一本书后调用：在后台按目录把整本书补齐。
    ///
    /// - `chapterId` 是起跑点（正在读的章），先向后下完再绕回开头；
    /// - 已缓存的章节直接跳过，不会重复请求；
    /// - 同一本书已经在跑（或暂停）时不重复启动，`force` 用于手动“重试”；
    /// - 切换到另一本书会取消上一本的队列。
    public func startWholeBookDownload(bookId: Int64,
                                       from chapterId: Int64? = nil,
                                       force: Bool = false) {
        withLock {
            if !force, wholeBookBookId == bookId, wholeBookTask != nil { return }

            wholeBookGeneration &+= 1
            let generation = wholeBookGeneration
            wholeBookTask?.cancel()
            wholeBookBookId = bookId
            wholeBookPaused = false
            wholeBookStatus = nil
            wholeBookTask = Task { [weak self] in
                guard let self else { return }
                await self.runWholeBookDownload(bookId: bookId,
                                                startingAt: chapterId,
                                                generation: generation)
            }
        }
    }

    /// 暂停整本下载：当前章若已经在请求中会先完成，之后不再发起新章节。
    public func pauseWholeBookDownload() {
        let snapshot: WholeBookDownloadStatus? = withLock {
            guard wholeBookTask != nil, !wholeBookPaused else { return nil }
            wholeBookPaused = true
            guard var status = wholeBookStatus, status.isActive else { return nil }
            status.phase = .paused
            status.nextAttemptAt = nil
            wholeBookStatus = status
            return status
        }
        if let snapshot { onWholeBookDownloadUpdate?(snapshot) }
    }

    public func resumeWholeBookDownload() {
        let snapshot: WholeBookDownloadStatus? = withLock {
            guard wholeBookTask != nil, wholeBookPaused else { return nil }
            wholeBookPaused = false
            guard var status = wholeBookStatus, status.phase == .paused else { return nil }
            status.phase = .waiting
            wholeBookStatus = status
            return status
        }
        if let snapshot { onWholeBookDownloadUpdate?(snapshot) }
    }

    private func runWholeBookDownload(bookId: Int64,
                                      startingAt chapterId: Int64?,
                                      generation: Int) async {
        defer { finishWholeBookTask(generation: generation) }

        var status = WholeBookDownloadStatus(bookId: bookId,
                                             bookName: "",
                                             totalChapters: 0,
                                             cachedChapters: 0,
                                             skippedChapters: 0,
                                             failedChapters: 0,
                                             phase: .preparing)
        publishWholeBook(status, generation: generation)

        let catalog: BookCatalog
        do {
            catalog = try await self.catalog(bookId: bookId)
        } catch {
            guard isWholeBookCurrent(generation) else { return }
            status.phase = .failed(error.localizedDescription)
            publishWholeBook(status, generation: generation)
            return
        }
        guard isWholeBookCurrent(generation) else { return }

        let cachedIds = Set(cache.cachedChapterIds(bookId: bookId))
        let unavailable = withLock { wholeBookUnavailable[bookId] ?? [] }
        let plan = WholeBookDownloadPlan(catalog: catalog,
                                         cachedChapterIds: cachedIds,
                                         unavailableChapterIds: unavailable,
                                         startingAt: chapterId)

        status.bookName = catalog.bookName
        status.totalChapters = plan.totalChapters
        status.cachedChapters = plan.cachedChapters
        status.skippedChapters = plan.unavailableChapters
        status.phase = .waiting
        publishWholeBook(status, generation: generation)

        guard !plan.chapters.isEmpty else {
            status.phase = .finished
            publishWholeBook(status, generation: generation)
            return
        }

        var consecutiveFailures = 0

        for item in plan.chapters {
            guard await waitWhileWholeBookPaused(generation: generation) else { return }

            // 建队列之后用户可能已经读过这一章，直接算作已缓存。
            if isChapterCachedNow(bookId: bookId, chapterId: item.chapterId) {
                status.cachedChapters += 1
                status.nextAttemptAt = nil
                publishWholeBook(status, generation: generation)
                continue
            }

            let interval = BookDownloadPacing.nextInterval()
            status.phase = .waiting
            status.nextAttemptAt = Date().addingTimeInterval(interval)
            status.currentChapterId = nil
            status.currentChapterTitle = nil
            publishWholeBook(status, generation: generation)

            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
            guard isWholeBookCurrent(generation),
                  await waitWhileWholeBookPaused(generation: generation) else { return }

            if isChapterCachedNow(bookId: bookId, chapterId: item.chapterId) {
                status.cachedChapters += 1
                status.nextAttemptAt = nil
                publishWholeBook(status, generation: generation)
                continue
            }

            status.phase = .downloading
            status.nextAttemptAt = nil
            status.currentChapterId = item.chapterId
            status.currentChapterTitle = item.displayTitle
            publishWholeBook(status, generation: generation)

            guard let outcome = await downloadWholeBookChapter(bookId: bookId,
                                                               chapterId: item.chapterId,
                                                               generation: generation) else {
                return
            }

            status.currentChapterId = nil
            status.currentChapterTitle = nil
            status.nextAttemptAt = nil
            switch outcome {
            case .cached:
                status.cachedChapters += 1
                consecutiveFailures = 0
            case .skipped:
                status.skippedChapters += 1
                consecutiveFailures = 0
            case .failed(let error):
                status.failedChapters += 1
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    status.phase = .failed("连续 \(consecutiveFailures) 章下载失败：\(error.localizedDescription)")
                    publishWholeBook(status, generation: generation)
                    return
                }
            }
            status.phase = .waiting
            publishWholeBook(status, generation: generation)
        }

        status.phase = .finished
        status.currentChapterId = nil
        status.currentChapterTitle = nil
        status.nextAttemptAt = nil
        publishWholeBook(status, generation: generation)
    }

    private enum WholeBookChapterOutcome {
        case cached
        case skipped
        case failed(Error)
    }

    /// 下载单章并归类结果；任务已被取消/替换时返回 nil。
    private func downloadWholeBookChapter(bookId: Int64,
                                          chapterId: Int64,
                                          generation: Int) async -> WholeBookChapterOutcome? {
        do {
            let chapter = try await self.chapter(bookId: bookId,
                                                 chapterId: chapterId,
                                                 prefetchNext: false)
            guard isWholeBookCurrent(generation) else { return nil }
            if chapter.isPreview {
                markWholeBookUnavailable(bookId: bookId, chapterId: chapterId)
                return .skipped
            }
            return .cached
        } catch {
            guard isWholeBookCurrent(generation) else { return nil }
            if Self.isNotPurchased(error) {
                markWholeBookUnavailable(bookId: bookId, chapterId: chapterId)
                return .skipped
            }
            return .failed(error)
        }
    }

    /// 暂停期间原地等待，恢复后返回 true；任务被取消/替换时返回 false。
    private func waitWhileWholeBookPaused(generation: Int) async -> Bool {
        while true {
            guard isWholeBookCurrent(generation) else { return false }
            guard withLock({ wholeBookPaused }) else { return true }

            let snapshot: WholeBookDownloadStatus? = withLock {
                guard var status = wholeBookStatus else { return nil }
                status.phase = .paused
                status.nextAttemptAt = nil
                guard wholeBookStatus != status else { return nil }
                wholeBookStatus = status
                return status
            }
            if let snapshot { onWholeBookDownloadUpdate?(snapshot) }

            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return false
            }
        }
    }

    private func publishWholeBook(_ status: WholeBookDownloadStatus, generation: Int) {
        let accepted: WholeBookDownloadStatus? = withLock {
            guard wholeBookGeneration == generation else { return nil }
            guard wholeBookStatus != status else { return nil }
            wholeBookStatus = status
            return status
        }
        if let accepted { onWholeBookDownloadUpdate?(accepted) }
    }

    private func finishWholeBookTask(generation: Int) {
        withLock {
            guard wholeBookGeneration == generation else { return }
            wholeBookTask = nil
        }
    }

    private func isWholeBookCurrent(_ generation: Int) -> Bool {
        if Task.isCancelled { return false }
        return withLock { wholeBookGeneration == generation }
    }

    private func isChapterCachedNow(bookId: Int64, chapterId: Int64) -> Bool {
        if cachedChapter(chapterId) != nil { return true }
        return cache.isCached(bookId: bookId, chapterId: chapterId)
    }

    private func markWholeBookUnavailable(bookId: Int64, chapterId: Int64) {
        _ = withLock { wholeBookUnavailable[bookId, default: []].insert(chapterId) }
    }

    private static func isNotPurchased(_ error: Error) -> Bool {
        guard let error = error as? QidianError else { return false }
        if case .notPurchased = error { return true }
        return false
    }

    /// `NSLock` 不能在 async 函数里直接 lock/unlock（Swift 6 会报错），
    /// 统一用这个同步作用域包一层。
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
