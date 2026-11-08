import SwiftUI
import AppKit
import QidianKit

/// 直接用 `swift run` / 双击可执行文件运行时，进程默认是 `.prohibited` 激活策略：
/// 窗口会创建，但没有 Dock 图标、不会激活到前台，看起来就像“没打开”。
/// 默认启动时这里显式改成普通 App 并抢一次焦点；
/// 带 `--no-activate` 启动时只改激活策略、不抢焦点、不置顶，窗口留在其他 App 的窗口后面。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = LaunchOptions.current

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--no-activate`：不激活 App、不把窗口提到最前，
        // 窗口照常创建并可用，但会排在其他 App 的窗口后面。
        guard !options.suppressesForeground else { return }
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
        @Bindable var store = store
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
        .background(store.theme.background)
        .navigationTitle(store.chapter?.title ?? "QidianReader")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ReaderFunctionMenu()
            }
        }
        .sheet(isPresented: $store.isPresentingLogin) {
            LoginSheet { cookies in
                store.finishLogin(cookies: cookies)
            }
        }
        .sheet(isPresented: $store.isPresentingOpenChapter) {
            OpenChapterSheet()
        }
        .task {
            await store.restoreLastReadingIfNeeded()
        }
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

            Text("从左上角「功能」菜单打开章节")
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

            Button("打开章节链接…") { store.isPresentingOpenChapter = true }
                .buttonStyle(.borderedProminent)

            if !store.isLoggedIn {
                Text("付费章节需要先在功能菜单登录；免费章节不登录也能读。")
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
