import SwiftUI
import QidianKit

/// 阅读窗口左上角的唯一入口。
///
/// 顶部工具栏和底部状态栏都收进这个一级菜单，正文区域只保留左右两页。
struct ReaderFunctionMenu: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        Menu {
            readingInfo
            Divider()
            Menu("切换书籍") { bookList }
            Button("打开章节链接…") { store.isPresentingOpenChapter = true }
            Divider()
            fontSizeMenu
            themeMenu
            Divider()
            loginItem
        } label: {
            Label("功能", systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("阅读功能")
    }

    // MARK: - Status

    @ViewBuilder
    private var readingInfo: some View {
        if let chapter = store.chapter {
            Button(chapter.bookName.isEmpty ? chapter.title : "《\(chapter.bookName)》") {}
                .disabled(true)

            if let status = store.readingStatus {
                Button(status.pageText) {}
                    .disabled(true)
                if !status.hint.isEmpty {
                    Button(status.hint) {}
                        .disabled(true)
                }
            }
        } else {
            Button("尚未打开章节") {}
                .disabled(true)
        }
    }

    // MARK: - Books

    @ViewBuilder
    private var bookList: some View {
        if store.recentBooks.isEmpty {
            Button("还没有读过的书") {}
                .disabled(true)
        } else {
            ForEach(store.recentBooks) { entry in
                Button(bookMenuLabel(entry)) {
                    Task { await store.openHistoryEntry(entry) }
                }
            }
        }
    }

    /// 当前书打勾，并带上该书上次读到的章节名。
    private func bookMenuLabel(_ entry: ReadingHistoryEntry) -> String {
        let name = entry.bookName.isEmpty ? "书籍 \(entry.bookId)" : entry.bookName
        let mark = store.chapter?.bookId == entry.bookId ? "✓ " : ""
        let chapter = entry.chapterTitle.isEmpty ? "" : " · \(entry.chapterTitle)"
        return mark + name + chapter
    }

    // MARK: - Type & theme

    private var fontSizeMenu: some View {
        Menu("字号：\(Int(store.fontSize))") {
            Button("增大字号") { store.fontSize = min(30, store.fontSize + 1) }
            Button("减小字号") { store.fontSize = max(14, store.fontSize - 1) }
        }
    }

    private var themeMenu: some View {
        Menu("主题：\(store.theme.label)") {
            ForEach(ReaderTheme.allCases) { theme in
                Button {
                    store.theme = theme
                } label: {
                    if store.theme == theme {
                        Label(theme.label, systemImage: "checkmark")
                    } else {
                        Text(theme.label)
                    }
                }
            }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var loginItem: some View {
        if store.isLoggedIn {
            Button("已登录") {}
                .disabled(true)
        } else {
            Button("登录…") { store.login() }
        }
    }
}

/// 从功能菜单打开新章节。窗口顶部不再常驻链接输入框。
struct OpenChapterSheet: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            Text("打开章节")
                .font(.headline)

            Text("粘贴起点章节链接，或直接输入 bookId chapterId。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("https://www.qidian.com/chapter/...", text: $store.input)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(open)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("阅读") { open() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { isFocused = true }
    }

    private func open() {
        dismiss()
        Task { await store.openInput() }
    }
}
