import AppKit
import SwiftUI
import QidianKit

/// 功能菜单里的「章节目录」。
///
/// 目录一次拉回整本书，按卷分组展示；点任意一章就关掉 sheet 并载入正文。
/// 顶部可以在当前书和读过的书之间切换目录，搜索框按章节名过滤。
///
/// 1000+ 章的目录如果一次性建成 SwiftUI 视图会明显卡顿，所以列表是**懒加载**的：
/// `CatalogListLayout` 把目录算成固定行高的扁平行（只做几何计算），
/// 这里按滚动位置只渲染「可视范围 + 上下缓冲区」的那几十行，
/// 其余行用空白占位撑住总高度，滚动条长度和滚动位置都不会变。
struct ChapterCatalogSheet: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var collapsedVolumes: Set<Int64> = []
    @State private var bookInput = ""
    @State private var isEnteringBook = false

    /// 扁平化后的目录行：只在目录 / 搜索词 / 折叠状态变化时重建。
    @State private var layout = CatalogListLayout()
    /// 列表当前实际渲染的行区间；滚动时按可视范围滑动。
    @State private var windowRange: Range<Int> = 0..<0
    /// 滚动状态（偏移 / 可视高度 / NSScrollView 句柄）。引用类型，滚动时更新不会触发刷新。
    @State private var scrollState = CatalogScrollState()
    /// 布局对应的书；目录刚拉回来、布局还没重建时先不渲染，避免闪出上一本书的行。
    @State private var layoutBookId: Int64?

    /// 可视范围上下各多渲染一屏，快速滑动 / 惯性滚动时不会露出空白。
    private static let bufferViewportFactor: CGFloat = 1
    /// 还没量到 ScrollView 高度时（首帧）用的估计值。
    private static let fallbackViewportHeight: CGFloat = 480

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 700, height: 620)
        // 布局重建必须挂在这层：目录刚拉回来时列表还没进视图树，藏在列表里的 onChange 不会触发。
        .onChange(of: layoutKey, initial: true) { _, _ in
            rebuildLayout()
        }
        .onChange(of: store.catalogBookId) { _, _ in
            query = ""
            collapsedVolumes = []
            bookInput = ""
            isEnteringBook = false
        }
        .onChange(of: store.catalog?.bookId) { _, _ in
            collapsedVolumes = []
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(store.catalogBookName ?? "章节目录")
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)

                        if let status = store.catalog?.bookStatus, !status.isEmpty {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if store.catalogBooks.count > 1 {
                    bookPicker
                }

                Button {
                    isEnteringBook = true
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("输入书籍 ID 或书籍页链接，读取其他书的目录")

                Button(action: refresh) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing || store.catalogBookId == nil)
                .help("刷新目录")
            }

            if isEnteringBook || store.catalogBookId == nil {
                bookEntryBar
            } else {
                TextField("搜索章节名", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var bookEntryBar: some View {
        HStack(spacing: 8) {
            TextField("书籍 ID 或书籍页链接", text: $bookInput)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(openBookFromInput)

            Button("读取目录", action: openBookFromInput)
                .disabled(BookRef(bookInput) == nil)

            if store.catalogBookId != nil {
                Button("取消") {
                    isEnteringBook = false
                    bookInput = ""
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func openBookFromInput() {
        guard let ref = BookRef(bookInput) else { return }
        isEnteringBook = false
        bookInput = ""
        Task { await store.loadCatalog(bookId: ref.bookId) }
    }

    private var subtitle: String {
        guard let catalog = store.catalog else {
            return store.catalogBookId == nil
                ? "输入书籍 ID 或书籍页链接，读取整本书的章节目录"
                : "读取这本书的章节列表"
        }
        var parts = ["\(catalog.volumes.count) 卷", "\(catalog.chapterCount) 章"]
        if let chapter = store.chapter,
           chapter.bookId == catalog.bookId,
           !chapter.authorName.isEmpty {
            parts.append(chapter.authorName)
        }
        return parts.joined(separator: " · ")
    }

    private var bookPicker: some View {
        Menu {
            ForEach(store.catalogBooks) { book in
                Button {
                    Task { await store.loadCatalog(bookId: book.bookId) }
                } label: {
                    if book.bookId == (store.catalog?.bookId ?? store.catalogBookId) {
                        Label(bookTitle(book), systemImage: "checkmark")
                    } else {
                        Text(bookTitle(book))
                    }
                }
            }
        } label: {
            Label("书籍", systemImage: "books.vertical")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换到其他读过的书的目录")
    }

    private func bookTitle(_ book: ReaderStore.CatalogBook) -> String {
        book.bookName.isEmpty ? "书籍 \(book.bookId)" : book.bookName
    }

    private var isRefreshing: Bool {
        if case .loading = store.catalogPhase { return true }
        return false
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let catalog = store.catalog, catalog.bookId == layoutBookId {
            catalogList(catalog)
        } else if case .failed(let message) = store.catalogPhase {
            failureView(message)
        } else if store.catalogBookId == nil {
            emptyBookView
        } else {
            ProgressView("加载目录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func catalogList(_ catalog: BookCatalog) -> some View {
        VStack(spacing: 0) {
            if !layout.keyword.isEmpty, !layout.rows.isEmpty {
                searchHeader(count: layout.rows.count)
            }

            if layout.rows.isEmpty {
                if layout.keyword.isEmpty {
                    emptyCatalogView
                } else {
                    emptySearchView
                }
            } else {
                scrollView
            }
        }
        .onChange(of: query) { _, _ in
            Task { await resetScrollToTop() }
        }
        .task(id: catalog.bookId) {
            await scrollToInitialPosition()
        }
    }

    private var scrollView: some View {
        ScrollView(.vertical) {
            rows
                .background {
                    CatalogScrollObserver(state: scrollState) {
                        scheduleWindowUpdate()
                    }
                }
        }
    }

    /// 只把窗口内的几十行交给 SwiftUI，其余高度用透明占位撑住。
    private var rows: some View {
        let range = layout.clampedRange(windowRange)
        let spans = layout.spans(for: range)

        return VStack(spacing: 0) {
            Color.clear.frame(height: spans.top)

            ForEach(layout.rows[range]) { row in
                rowView(row)
            }

            Color.clear.frame(height: spans.bottom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: CatalogListLayout.Row) -> some View {
        switch row.kind {
        case .volume(let volumeId, let title, let chapterCount, let collapsed):
            volumeHeader(volumeId: volumeId,
                         title: title,
                         chapterCount: chapterCount,
                         collapsed: collapsed)
                .frame(height: row.height)

        case .chapter(let chapter, let volumeName):
            CatalogChapterRow(chapter: chapter,
                              volumeName: volumeName,
                              isCurrent: store.currentCatalogChapterId == chapter.chapterId) {
                store.openCatalogChapter(chapter)
            }
            .frame(height: row.height)
        }
    }

    private func volumeHeader(volumeId: Int64,
                              title: String,
                              chapterCount: Int,
                              collapsed: Bool) -> some View {
        Button {
            // 行位置是算出来的，折叠不做动画：动画会和窗口滑动互相打架。
            if collapsed {
                collapsedVolumes.remove(volumeId)
            } else {
                collapsedVolumes.insert(volumeId)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text("\(chapterCount) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func searchHeader(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("搜索结果").font(.subheadline.weight(.semibold))
            Text("\(count) 章").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var emptySearchView: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有匹配的章节")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyCatalogView: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("这本书还没有章节")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyBookView: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有打开过书")
                .font(.headline)
            Text("在上面的输入框里填写书籍 ID 或书籍页链接\n例如 1037095853 或 https://m.qidian.com/book/1037095853/")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("目录加载失败")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 8) {
                Button("重试", action: refresh)
                    .buttonStyle(.borderedProminent)
                Button("打开其他书籍…") { isEnteringBook = true }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if isRefreshing, store.catalog != nil {
                ProgressView().controlSize(.small)
                Text("正在刷新目录…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = store.catalogPhase {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let catalog = store.catalog {
                Text("共 \(catalog.chapterCount) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !store.isLoggedIn {
                Text("未登录：收费章节只能试读")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Layout

    /// 布局输入：目录内容（revision 变化）、搜索词、折叠状态任一变化都要重建。
    private struct LayoutKey: Equatable {
        var revision: Int
        var bookId: Int64?
        var keyword: String
        var collapsed: Set<Int64>
    }

    private var layoutKey: LayoutKey {
        LayoutKey(revision: store.catalogRevision,
                  bookId: store.catalog?.bookId,
                  keyword: query.trimmingCharacters(in: .whitespacesAndNewlines),
                  collapsed: collapsedVolumes)
    }

    private func rebuildLayout() {
        guard let catalog = store.catalog else {
            layout = CatalogListLayout()
            layoutBookId = nil
            windowRange = 0..<0
            return
        }

        let next = CatalogListLayout(catalog: catalog,
                                     collapsedVolumes: collapsedVolumes,
                                     query: query)
        layoutBookId = catalog.bookId
        guard next != layout else { return }
        layout = next
        // 重建后按当前滚动位置重新取窗口，避免中间帧空白。
        windowRange = next.window(visibleTop: visibleTop,
                                  visibleHeight: viewportHeight,
                                  buffer: windowBuffer)
    }

    private var visibleTop: CGFloat {
        max(0, scrollState.offsetY)
    }

    private var viewportHeight: CGFloat {
        scrollState.viewportHeight > 0 ? scrollState.viewportHeight : Self.fallbackViewportHeight
    }

    private var windowBuffer: CGFloat {
        viewportHeight * Self.bufferViewportFactor
    }

    private func windowStarting(at top: CGFloat) -> Range<Int> {
        layout.window(visibleTop: top, visibleHeight: viewportHeight, buffer: windowBuffer)
    }

    /// 滚动通知里同步改 @State 会被 SwiftUI 丢掉（回调正好在一次视图更新里），
    /// 所以统一挪到下一轮主线程；同一轮里的多个通知只算一次。
    private func scheduleWindowUpdate() {
        guard !scrollState.updateScheduled else { return }
        scrollState.updateScheduled = true
        DispatchQueue.main.async {
            scrollState.updateScheduled = false
            updateWindow()
        }
    }

    private func updateWindow() {
        guard !layout.rows.isEmpty else {
            if windowRange != 0..<0 { windowRange = 0..<0 }
            return
        }
        let next = windowStarting(at: visibleTop)
        guard next != windowRange else { return }
        windowRange = next
    }

    /// 滚到某一行；`centered` 为 false 时该行贴顶。
    private func scroll(toRowIndex index: Int, centered: Bool) async {
        guard let row = layout.row(at: index) else { return }
        let height = viewportHeight
        let top = centered
            ? max(0, row.offset + row.height / 2 - height / 2)
            : row.offset
        // 先把窗口和测量值挪到目标位置，再滚 NSScrollView：
        // 目标行还没渲染出来，ScrollViewReader 找不到它，只能直接改滚动位置。
        scrollState.offsetY = top
        windowRange = windowStarting(at: top)
        scrollState.scroll(toOffsetFromTop: top)

        // 首帧内容还没布局完时 documentView 高度是 0，滚动会被夹回顶部，稍后补一次。
        if abs(scrollState.offsetY - top) > 2 {
            try? await Task.sleep(nanoseconds: 80_000_000)
            scrollState.scroll(toOffsetFromTop: top)
        }
    }

    private func scrollToTop() {
        scrollState.offsetY = 0
        windowRange = windowStarting(at: 0)
        scrollState.scroll(toOffsetFromTop: 0)
    }

    // MARK: - Actions

    private func refresh() {
        guard let bookId = store.catalogBookId else { return }
        Task { await store.loadCatalog(bookId: bookId, forceRefresh: true) }
    }

    /// 打开目录时的初始位置：当前章在本书里就定位过去（并展开所在卷），否则回到顶部。
    private func scrollToInitialPosition() async {
        // 等首帧布局 / 目录重建完成。
        try? await Task.sleep(nanoseconds: 60_000_000)

        guard !layout.rows.isEmpty, layout.keyword.isEmpty else { return }

        if let currentId = store.currentCatalogChapterId,
           let volumeId = layout.volumeId(containingChapterId: currentId),
           collapsedVolumes.contains(volumeId) {
            collapsedVolumes.remove(volumeId)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        guard let currentId = store.currentCatalogChapterId,
              let index = layout.index(ofChapterId: currentId) else {
            scrollToTop()
            return
        }
        await scroll(toRowIndex: index, centered: true)
    }

    /// 搜索词变化后回到顶部：搜索结果和按卷浏览的行位置完全不是一回事。
    private func resetScrollToTop() async {
        try? await Task.sleep(nanoseconds: 40_000_000)
        scrollToTop()
    }
}

// MARK: - Row

/// 目录里的一章。悬停状态放在行内部，鼠标划过不会让整张目录重算。
private struct CatalogChapterRow: View {
    let chapter: CatalogChapter
    let volumeName: String?
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.displayTitle)
                        .font(.callout)
                        .lineLimit(1)

                    if let volumeName, !volumeName.isEmpty {
                        Text(volumeName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if chapter.isPaid {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("订阅章节；未购买时只能试读片段")
                }

                if isCurrent {
                    Text("在读")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }

                if chapter.wordCount > 0 {
                    Text("\(chapter.wordCount) 字")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(chapter.wordCount > 0
              ? "\(chapter.displayTitle) · \(chapter.wordCount) 字"
              : chapter.displayTitle)
    }

    private var background: Color {
        if isCurrent { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.06) }
        return .clear
    }
}

// MARK: - Scroll metrics

/// 目录列表的滚动状态，同时拿着 SwiftUI `ScrollView` 背后的 `NSScrollView`。
///
/// 用引用类型：滚动通知每一帧都会写 `offsetY` / `viewportHeight`，不能因此触发视图刷新，
/// 只有窗口区间真的变了才更新 SwiftUI 状态（见 `scheduleWindowUpdate`）。
/// 跳章也靠它直接改滚动位置——目标行还没渲染，`ScrollViewReader` 找不到。
private final class CatalogScrollState {
    /// 内容顶部到可视区域顶部的距离（0 = 在顶部）。
    var offsetY: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// 是否已经安排了一次窗口重算，避免同一个 runloop 里重复刷新。
    var updateScheduled = false
    weak var scrollView: NSScrollView?

    /// 滚动到「内容顶部往下 offset」的位置。
    func scroll(toOffsetFromTop offset: CGFloat) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxOffset = max(0, documentView.bounds.height - clip.bounds.height)
        let clamped = min(max(offset, 0), maxOffset)
        let y = documentView.isFlipped
            ? clamped
            : max(0, documentView.bounds.height - clip.bounds.height - clamped)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// 读取 SwiftUI `ScrollView` 背后 `NSScrollView` 的滚动位置。
///
/// macOS 上滚动不会触发 SwiftUI 布局，iOS 那套
/// `GeometryReader` + `PreferenceKey` 在这里收不到回调（实测滚动后 GeometryReader
/// 的 frame 一直不变），窗口就不会跟着可视范围滑动，滚动后只剩空白。
/// 所以直接监听 `NSScrollView` 的 clipView 通知：滚动和改窗口大小都能拿到
/// 「滚了多远」和「可视多高」。
private struct CatalogScrollObserver: NSViewRepresentable {
    let state: CatalogScrollState
    /// 滚动位置变了之后回调（调用方负责安排窗口重算）。
    let onUpdate: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.state = state
        view.onUpdate = onUpdate
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.state = state
        nsView.onUpdate = onUpdate
        nsView.attachIfNeeded()
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.detach()
    }

    final class ObserverView: NSView {
        var state: CatalogScrollState?
        var onUpdate: (() -> Void)?
        private weak var clipView: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 刚插进视图树时 enclosingScrollView 可能还没就绪，下一轮再挂。
            DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
        }

        func attachIfNeeded() {
            guard let scrollView = enclosingScrollView else { return }
            state?.scrollView = scrollView

            let clip = scrollView.contentView
            guard clipView !== clip else { return }
            detach()
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(metricsDidChange),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: clip)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(metricsDidChange),
                                                   name: NSView.frameDidChangeNotification,
                                                   object: clip)
            clipView = clip
            report()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self,
                                                      name: NSView.boundsDidChangeNotification,
                                                      object: clipView)
            NotificationCenter.default.removeObserver(self,
                                                      name: NSView.frameDidChangeNotification,
                                                      object: clipView)
            clipView = nil
        }

        @objc private func metricsDidChange() {
            report()
        }

        private func report() {
            guard let clipView else { return }
            state?.offsetY = clipView.bounds.origin.y
            state?.viewportHeight = clipView.bounds.height
            onUpdate?()
        }
    }
}
