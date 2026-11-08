import SwiftUI
import AppKit
import QidianKit

/// 直接用 `swift run` / 双击可执行文件运行时，进程默认是 `.prohibited` 激活策略：
/// 窗口会创建，但没有 Dock 图标、不会激活到前台，看起来就像“没打开”。
/// 这里显式改成普通 App 并抢一次焦点。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct QidianReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ReaderStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 900, height: 760)
        .windowToolbarStyle(.unifiedCompact)
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ReaderTopBar()
            Divider()
            ZStack(alignment: .bottom) {
                if let chapter = store.chapter {
                    ReaderView(chapter: chapter)
                } else {
                    WelcomeView()
                }

                if case .loading(let text) = store.phase {
                    LoadingBadge(text: text)
                }
                if case .failed(let message) = store.phase {
                    ErrorBanner(message: message)
                }
            }
        }
        .background(store.theme.background)
        .navigationTitle(store.chapter?.title ?? "QidianReader")
        .task {
            await store.restoreLastReadingIfNeeded()
        }
    }
}

// MARK: - Top bar

struct ReaderTopBar: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            Menu {
                Menu("切换书籍") {
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
            } label: {
                Label("书库", systemImage: "books.vertical")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("书库：切换之前读过的书")

            TextField("粘贴章节链接，例如 https://www.qidian.com/chapter/1037095853/801714441/",
                      text: $store.input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await store.openInput() } }

            Button("阅读") {
                Task { await store.openInput() }
            }
            .keyboardShortcut(.return, modifiers: [])

            Divider().frame(height: 18)

            Button {
                store.fontSize = max(14, store.fontSize - 1)
            } label: { Image(systemName: "textformat.size.smaller") }
                .buttonStyle(.plain)

            Button {
                store.fontSize = min(30, store.fontSize + 1)
            } label: { Image(systemName: "textformat.size.larger") }
                .buttonStyle(.plain)

            Picker("", selection: $store.theme) {
                ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            if store.isLoggedIn {
                Label("已登录", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("登录") { store.login() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 菜单项文案：当前书打勾，并带上该书上次读到的章节名。
    private func bookMenuLabel(_ entry: ReadingHistoryEntry) -> String {
        let name = entry.bookName.isEmpty ? "书籍 \(entry.bookId)" : entry.bookName
        let mark = store.chapter?.bookId == entry.bookId ? "✓ " : ""
        let chapter = entry.chapterTitle.isEmpty ? "" : " · \(entry.chapterTitle)"
        return mark + name + chapter
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.pages")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)

            Text("把章节链接粘到上面，点“阅读”")
                .font(.title3.weight(.medium))

            VStack(alignment: .leading, spacing: 6) {
                Text("支持：")
                Text("https://www.qidian.com/chapter/1037095853/801714441/")
                Text("https://m.qidian.com/chapter/1037095853/801714441/")
                Text("也可以直接输 1037095853 801714441")
            }
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            if !store.isLoggedIn {
                Text("付费章节需要先登录；免费章节不登录也能读。")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reader

struct ReaderView: View {
    let chapter: LoadedChapter

    var body: some View {
        PagedReaderView(chapter: chapter)
    }
}

// MARK: - Overlays

struct LoadingBadge: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 18)
    }
}

struct ErrorBanner: View {
    @Environment(ReaderStore.self) private var store
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).lineLimit(3)
            if store.chapter != nil {
                Button("重试") { Task { await store.retry() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }
}
