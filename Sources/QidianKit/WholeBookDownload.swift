import Foundation

/// 整本书后台下载的进度快照，供功能菜单显示。
public struct WholeBookDownloadStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// 正在拉目录、计算要下载哪些章。
        case preparing
        /// 队列已排好，等 1–2 分钟后再下载下一章。
        case waiting
        /// 正在下载当前章。
        case downloading
        /// 用户手动暂停。
        case paused
        /// 队列跑完（可能仍有跳过/失败的章节）。
        case finished
        /// 目录拉取失败，或连续多章失败后中止。
        case failed(String)
    }

    public var bookId: Int64
    public var bookName: String
    public var totalChapters: Int
    /// 已缓存章数：开始时统计磁盘上已有，之后每成功下载一章加一。
    public var cachedChapters: Int
    /// 已确认读不了、本次跳过的章数（未购买 / 只拿到试读）。
    public var skippedChapters: Int
    /// 下载失败的章数。
    public var failedChapters: Int
    public var phase: Phase
    public var currentChapterId: Int64?
    public var currentChapterTitle: String?
    /// 下一次尝试的时间（仅 `.waiting` 有值）。
    public var nextAttemptAt: Date?

    public init(bookId: Int64,
                bookName: String,
                totalChapters: Int,
                cachedChapters: Int,
                skippedChapters: Int,
                failedChapters: Int,
                phase: Phase,
                currentChapterId: Int64? = nil,
                currentChapterTitle: String? = nil,
                nextAttemptAt: Date? = nil) {
        self.bookId = bookId
        self.bookName = bookName
        self.totalChapters = totalChapters
        self.cachedChapters = cachedChapters
        self.skippedChapters = skippedChapters
        self.failedChapters = failedChapters
        self.phase = phase
        self.currentChapterId = currentChapterId
        self.currentChapterTitle = currentChapterTitle
        self.nextAttemptAt = nextAttemptAt
    }

    /// 还没缓存、也还没被跳过/失败的章数。
    public var remainingChapters: Int {
        max(0, totalChapters - cachedChapters - skippedChapters - failedChapters)
    }

    public var isActive: Bool {
        switch phase {
        case .preparing, .waiting, .downloading:
            return true
        case .paused, .finished, .failed:
            return false
        }
    }
}

/// 把整本书目录排成后台下载队列。
///
/// - 从 `startingAt`（通常是当前正在读的章）开始，按目录顺序向后走；
///   走到全书结尾后绕回第一章，保证最终覆盖整本书。
/// - 跳过已缓存和本次已确认读不了（未购买/试读）的章节，避免重复下载。
public struct WholeBookDownloadPlan: Sendable {
    public let totalChapters: Int
    public let cachedChapters: Int
    public let unavailableChapters: Int
    public let chapters: [CatalogChapter]

    public init(catalog: BookCatalog,
                cachedChapterIds: Set<Int64>,
                unavailableChapterIds: Set<Int64> = [],
                startingAt chapterId: Int64? = nil) {
        // 真实目录偶尔会有重复/占位条目，先按 chapterId 去重并丢掉非法值。
        var valid: [CatalogChapter] = []
        var validIds: Set<Int64> = []
        for chapter in catalog.allChapters where chapter.chapterId > 0 {
            if validIds.insert(chapter.chapterId).inserted {
                valid.append(chapter)
            }
        }

        totalChapters = valid.count
        cachedChapters = valid.reduce(0) { partial, chapter in
            partial + (cachedChapterIds.contains(chapter.chapterId) ? 1 : 0)
        }
        unavailableChapters = valid.reduce(0) { partial, chapter in
            guard !cachedChapterIds.contains(chapter.chapterId) else { return partial }
            return partial + (unavailableChapterIds.contains(chapter.chapterId) ? 1 : 0)
        }

        guard !valid.isEmpty else {
            chapters = []
            return
        }

        let startIndex = chapterId
            .flatMap { id in valid.firstIndex(where: { $0.chapterId == id }) } ?? 0

        var queue: [CatalogChapter] = []
        for offset in 0..<valid.count {
            let chapter = valid[(startIndex + offset) % valid.count]
            guard !cachedChapterIds.contains(chapter.chapterId),
                  !unavailableChapterIds.contains(chapter.chapterId) else { continue }
            queue.append(chapter)
        }
        chapters = queue
    }
}

/// 后台下载的节奏：每两章之间等待 1 分钟 + 1 分钟 × 随机数。
public enum BookDownloadPacing {
    public static let baseInterval: TimeInterval = 60
    public static let jitterInterval: TimeInterval = 60

    /// `randomValue` 应在 `[0, 1)` 内；这里做一次裁剪，方便测试与外部调用。
    public static func interval(randomValue: Double) -> TimeInterval {
        baseInterval + jitterInterval * min(max(randomValue, 0), 1)
    }

    /// 下一次下载前的等待时间：60–120 秒。
    public static func nextInterval() -> TimeInterval {
        interval(randomValue: Double.random(in: 0..<1))
    }
}
