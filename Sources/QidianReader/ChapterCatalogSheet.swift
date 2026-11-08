import SwiftUI
import QidianKit

/// 功能菜单里的「章节目录」。
///
/// 目录一次拉回整本书，按卷分组展示；点任意一章就关掉 sheet 并载入正文。
/// 顶部可以在当前书和读过的书之间切换目录，搜索框按章节名过滤。
struct ChapterCatalogSheet: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var collapsedVolumes: Set<Int64> = []
    @State private var hoveredChapterId: Int64?
    @State private var bookInput = ""
    @State private var isEnteringBook = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 700, height: 620)
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
        if let catalog = store.catalog {
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
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = keyword.isEmpty ? [] : catalog.chapters(matching: keyword)

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if keyword.isEmpty {
                        ForEach(catalog.volumes) { volume in
                            volumeHeader(volume)
                            if !collapsedVolumes.contains(volume.id) {
                                ForEach(volume.chapters) { chapter in
                                    chapterRow(chapter, volumeName: nil)
                                }
                            }
                        }
                    } else if results.isEmpty {
                        emptySearchView
                    } else {
                        searchHeader(count: results.count)
                        ForEach(results) { chapter in
                            chapterRow(chapter,
                                       volumeName: catalog.volume(containing: chapter.chapterId)?.displayName)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .task(id: catalog.bookId) {
                await scrollToCurrentChapter(using: proxy)
            }
        }
    }

    private func volumeHeader(_ volume: CatalogVolume) -> some View {
        let collapsed = collapsedVolumes.contains(volume.id)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsed {
                    collapsedVolumes.remove(volume.id)
                } else {
                    collapsedVolumes.insert(volume.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text(volume.displayName)
                    .font(.subheadline.weight(.semibold))

                Text("\(volume.chapterCount) 章")
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

    private func chapterRow(_ chapter: CatalogChapter, volumeName: String?) -> some View {
        let isCurrent = store.currentCatalogChapterId == chapter.chapterId
        let isHovered = hoveredChapterId == chapter.chapterId

        return Button {
            store.openCatalogChapter(chapter)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.displayTitle)
                        .font(.callout)
                        .lineLimit(1)

                    if let volumeName, !volumeName.isEmpty {
                        Text(volumeName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
            .background(rowBackground(isCurrent: isCurrent, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredChapterId = hovering ? chapter.chapterId : nil
        }
        .id(chapter.chapterId)
        .help(chapter.wordCount > 0
              ? "\(chapter.displayTitle) · \(chapter.wordCount) 字"
              : chapter.displayTitle)
    }

    private func rowBackground(isCurrent: Bool, isHovered: Bool) -> Color {
        if isCurrent { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.06) }
        return .clear
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
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

    // MARK: - Actions

    private func refresh() {
        guard let bookId = store.catalogBookId else { return }
        Task { await store.loadCatalog(bookId: bookId, forceRefresh: true) }
    }

    private func scrollToCurrentChapter(using proxy: ScrollViewProxy) async {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let catalog = store.catalog,
              let currentId = store.currentCatalogChapterId else { return }

        if let volume = catalog.volume(containing: currentId) {
            collapsedVolumes.remove(volume.id)
        }
        // 等列表完成首次布局后再滚动，否则 ScrollViewReader 找不到目标行。
        try? await Task.sleep(nanoseconds: 150_000_000)
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(currentId, anchor: .center)
        }
    }
}
