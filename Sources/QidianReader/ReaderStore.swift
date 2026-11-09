import Foundation
import Observation
import SwiftUI
import QidianKit

@MainActor
@Observable
final class ReaderStore {
    enum Phase: Equatable {
        case idle
        case loading(String)
        case failed(String)
    }

    /// 分页视图上报给左上角功能菜单的阅读状态。
    struct ReadingStatus: Equatable {
        let pageText: String
        let hint: String
    }

    /// 目录里可切换的书籍：当前书 + 读过的书。
    struct CatalogBook: Identifiable, Equatable {
        let bookId: Int64
        let bookName: String
        var id: Int64 { bookId }
    }

    private(set) var phase: Phase = .idle
    private(set) var isLoggedIn = false
    private(set) var chapter: LoadedChapter?
    /// 之前读过的书，按最近阅读排序（每本书一条）。
    private(set) var recentBooks: [ReadingHistoryEntry] = []
    /// 当前加载/展示的目录。
    private(set) var catalog: BookCatalog?
    private(set) var catalogPhase: Phase = .idle
    private(set) var catalogBookId: Int64?
    /// 每次主动“跳到某个历史位置”时自增，用于让分页视图重新应用锚点。
    private(set) var restoreGeneration = 0
    /// 当前页码与翻页提示，只显示在功能菜单里。
    private(set) var readingStatus: ReadingStatus?
    /// 当前书的整本后台下载进度。
    private(set) var wholeBookDownload: WholeBookDownloadStatus?

    /// 用户粘贴的章节链接 / `bookId chapterId`。
    var input = ""
    var fontSize: Double = 19
    var lineSpacing: Double = 10
    var theme: ReaderTheme = .paper
    var isPresentingLogin = false
    var isPresentingOpenChapter = false
    var isPresentingCatalog = false

    private var session: QidianReadingSession
    private let history = ReadingHistoryStore()
    private var pendingRestore: ReadingHistoryEntry?
    private var didAttemptRestore = false
    private var loadGeneration = 0
    private var catalogGeneration = 0
    /// 已经为哪本书启动过整本下载，避免每次翻章都重启队列。
    private var wholeBookDownloadBookId: Int64?

    init() {
        if let jar = try? CookieJar.load(from: CookieJar.defaultURL) {
            session = QidianReadingSession(cookies: jar, cookieFile: CookieJar.defaultURL)
            isLoggedIn = jar.isLoggedIn
        } else {
            session = QidianReadingSession(cookies: CookieJar(), cookieFile: CookieJar.defaultURL)
        }
        recentBooks = history.entries
        session.onWholeBookDownloadUpdate = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.wholeBookDownload = status
            }
        }
    }

    // MARK: - Login

    func login() {
        isPresentingLogin = true
    }

    /// LoginSheet 拿到 Cookie 后回调。
    func finishLogin(cookies: [HTTPCookie]) {
        var jar = CookieJar(cookies: cookies)
        if let old = try? CookieJar.load(from: CookieJar.defaultURL) {
            var merged = old
            merged.merge(jar)
            jar = merged
        }
        try? jar.save(to: CookieJar.defaultURL)
        session.client.updateCookies(jar)
        session.clearCache()
        wholeBookDownloadBookId = nil
        wholeBookDownload = nil
        isLoggedIn = jar.isLoggedIn
        isPresentingLogin = false

        // 登录后如果已经在读，重新拉一次当前章（可能从试读变成全文）。
        if let current = chapter {
            Task { await self.load(bookId: current.bookId, chapterId: current.chapterId) }
        }
    }

    // MARK: - Reading

    /// 启动时恢复上次读到的章节和位置。
    func restoreLastReadingIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        guard chapter == nil, let entry = history.lastEntry else { return }

        pendingRestore = entry
        let ok = await load(bookId: entry.bookId, chapterId: entry.chapterId)
        if !ok {
            pendingRestore = nil
        }
    }

    func openInput() async {
        guard let ref = ChapterRef(input) else {
            phase = .failed("链接格式不对，示例：https://www.qidian.com/chapter/1037095853/801714441/")
            return
        }
        pendingRestore = nil
        await load(bookId: ref.bookId, chapterId: ref.chapterId)
    }

    /// 切换之前读过的书：载入该书上次读到的章节，并回到当时的页码。
    func openHistoryEntry(_ entry: ReadingHistoryEntry) async {
        pendingRestore = entry
        restoreGeneration &+= 1
        let token = restoreGeneration
        if await load(bookId: entry.bookId, chapterId: entry.chapterId) == false,
           token == restoreGeneration {
            pendingRestore = nil
        }
    }

    @discardableResult
    func openAdjacent(_ id: Int64?) async -> Bool {
        guard let id, let current = chapter else { return false }
        pendingRestore = nil
        return await load(bookId: current.bookId, chapterId: id)
    }

    func retry() async {
        guard let current = chapter else { return }
        pendingRestore = nil
        await load(bookId: current.bookId, chapterId: current.chapterId)
    }

    // MARK: - Catalog

    /// 目录 sheet 顶部可切换的书籍。
    var catalogBooks: [CatalogBook] {
        var books: [CatalogBook] = []
        if let chapter {
            books.append(CatalogBook(bookId: chapter.bookId, bookName: chapter.bookName))
        }
        for entry in recentBooks where !books.contains(where: { $0.bookId == entry.bookId }) {
            books.append(CatalogBook(bookId: entry.bookId, bookName: entry.bookName))
        }
        if let catalogBookId, !books.contains(where: { $0.bookId == catalogBookId }) {
            books.append(CatalogBook(bookId: catalogBookId, bookName: ""))
        }
        return books
    }

    var catalogBookName: String? {
        if let catalog, catalog.bookId == catalogBookId, !catalog.bookName.isEmpty {
            return catalog.bookName
        }
        let name = catalogBooks.first { $0.bookId == catalogBookId }?.bookName ?? ""
        return name.isEmpty ? nil : name
    }

    /// 目录中高亮“在读”的章节；目录切换到别的书时为 nil。
    var currentCatalogChapterId: Int64? {
        guard let chapter,
              let selectedBookId = catalog?.bookId ?? catalogBookId,
              chapter.bookId == selectedBookId else { return nil }
        return chapter.chapterId
    }

    /// 从功能菜单打开目录。默认展示当前书；没有在读的书时退回最近读过/上次看过的书。
    func presentCatalog() {
        isPresentingCatalog = true
        guard let target = chapter?.bookId ?? recentBooks.first?.bookId ?? catalogBookId else {
            catalog = nil
            catalogPhase = .idle
            catalogBookId = nil
            return
        }

        let needsLoad = catalog?.bookId != target
        catalogBookId = target
        if needsLoad {
            Task { await loadCatalog(bookId: target) }
        }
    }

    /// 加载（或刷新）一本书的目录。
    func loadCatalog(bookId: Int64, forceRefresh: Bool = false) async {
        catalogGeneration &+= 1
        let generation = catalogGeneration
        catalogBookId = bookId
        if catalog?.bookId != bookId {
            catalog = nil
        }
        catalogPhase = .loading("加载目录…")
        do {
            let loaded = try await session.catalog(bookId: bookId, forceRefresh: forceRefresh)
            guard generation == catalogGeneration else { return }
            catalog = loaded
            catalogPhase = .idle
        } catch {
            guard generation == catalogGeneration else { return }
            catalogPhase = .failed(error.localizedDescription)
        }
    }

    /// 从目录选章：先关掉 sheet，再载入章节。
    func openCatalogChapter(_ item: CatalogChapter) {
        guard let bookId = catalog?.bookId ?? catalogBookId else { return }
        isPresentingCatalog = false
        pendingRestore = nil
        Task { await load(bookId: bookId, chapterId: item.chapterId) }
    }

    /// 分页视图完成排版后取走待恢复的位置（启动恢复或切换书籍），只消费一次。
    func consumeRestoreAnchor(bookId: Int64, chapterId: Int64) -> Int? {
        guard let pendingRestore,
              pendingRestore.bookId == bookId,
              pendingRestore.chapterId == chapterId else { return nil }
        self.pendingRestore = nil
        return pendingRestore.anchor
    }

    /// `anchor` 相对正文起点，由 `PagedReaderView` 在翻页/重新分页后上报。
    func recordProgress(chapter: LoadedChapter, anchor: Int) {
        let changed = history.record(bookId: chapter.bookId,
                                     chapterId: chapter.chapterId,
                                     bookName: chapter.bookName,
                                     chapterTitle: chapter.title,
                                     anchor: anchor)
        if changed {
            recentBooks = history.entries
        }
    }

    /// 分页视图在排版/翻页后上报页码与提示，显示在功能菜单顶部。
    func updateReadingStatus(pageText: String, hint: String) {
        let status = ReadingStatus(pageText: pageText, hint: hint)
        guard readingStatus != status else { return }
        readingStatus = status
    }

    // MARK: - Whole-book background download

    func pauseWholeBookDownload() {
        session.pauseWholeBookDownload()
    }

    func resumeWholeBookDownload() {
        session.resumeWholeBookDownload()
    }

    /// 失败/有漏章时手动重跑一次队列；已缓存的章节仍会跳过。
    func retryWholeBookDownload() {
        guard let chapter else { return }
        wholeBookDownloadBookId = chapter.bookId
        session.startWholeBookDownload(bookId: chapter.bookId,
                                       from: chapter.chapterId,
                                       force: true)
    }

    /// 打开新书时启动整本后台下载；同一本书翻章不会重启队列。
    private func startWholeBookDownloadIfNeeded(for chapter: LoadedChapter) {
        guard wholeBookDownloadBookId != chapter.bookId else { return }
        wholeBookDownloadBookId = chapter.bookId
        session.startWholeBookDownload(bookId: chapter.bookId, from: chapter.chapterId)
    }

    @discardableResult
    private func load(bookId: Int64, chapterId: Int64) async -> Bool {
        loadGeneration &+= 1
        let generation = loadGeneration
        readingStatus = nil
        phase = .loading("加载正文…")
        do {
            let loaded = try await session.chapter(bookId: bookId, chapterId: chapterId)
            guard generation == loadGeneration else { return false }
            chapter = loaded
            input = "https://www.qidian.com/chapter/\(bookId)/\(chapterId)/"
            phase = .idle
            startWholeBookDownloadIfNeeded(for: loaded)
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            phase = .failed(error.localizedDescription)
            return false
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper, white, night

    var id: String { rawValue }
    var label: String {
        switch self {
        case .paper: return "纸黄"
        case .white: return "纯白"
        case .night: return "夜间"
        }
    }

    var background: Color {
        switch self {
        case .paper: return Color(red: 0.96, green: 0.93, blue: 0.86)
        case .white: return .white
        case .night: return Color(red: 0.09, green: 0.09, blue: 0.11)
        }
    }

    var foreground: Color {
        self == .night ? Color(white: 0.82) : Color(red: 0.15, green: 0.14, blue: 0.12)
    }

    var secondaryForeground: Color {
        foreground.opacity(0.55)
    }

    var tertiaryForeground: Color {
        foreground.opacity(0.40)
    }

    /// 分页纸面的底色，比整页背景略亮/略暗一点，突出“左右两页”。
    var pageBackground: Color {
        switch self {
        case .paper: return Color(red: 0.98, green: 0.96, blue: 0.90)
        case .white: return .white
        case .night: return Color(red: 0.12, green: 0.12, blue: 0.14)
        }
    }

    var pageBorder: Color {
        self == .night ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    var pageShadow: Color {
        self == .night ? Color.black.opacity(0.45) : Color.black.opacity(0.10)
    }
}

