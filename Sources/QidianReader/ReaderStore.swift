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

    private(set) var phase: Phase = .idle
    private(set) var isLoggedIn = false
    private(set) var chapter: LoadedChapter?

    /// 用户粘贴的章节链接 / `bookId chapterId`。
    var input = ""
    var fontSize: Double = 19
    var lineSpacing: Double = 10
    var theme: ReaderTheme = .paper
    var isPresentingLogin = false

    private var session: QidianReadingSession

    init() {
        if let jar = try? CookieJar.load(from: CookieJar.defaultURL) {
            session = QidianReadingSession(cookies: jar, cookieFile: CookieJar.defaultURL)
            isLoggedIn = jar.isLoggedIn
        } else {
            session = QidianReadingSession(cookies: CookieJar(), cookieFile: CookieJar.defaultURL)
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
        isLoggedIn = jar.isLoggedIn
        isPresentingLogin = false

        // 登录后如果已经在读，重新拉一次当前章（可能从试读变成全文）。
        if let current = chapter {
            Task { await self.load(bookId: current.bookId, chapterId: current.chapterId) }
        }
    }

    // MARK: - Reading

    func openInput() async {
        guard let ref = ChapterRef(input) else {
            phase = .failed("链接格式不对，示例：https://www.qidian.com/chapter/1037095853/801714441/")
            return
        }
        await load(bookId: ref.bookId, chapterId: ref.chapterId)
    }

    @discardableResult
    func openAdjacent(_ id: Int64?) async -> Bool {
        guard let id, let current = chapter else { return false }
        return await load(bookId: current.bookId, chapterId: id)
    }

    func retry() async {
        guard let current = chapter else { return }
        await load(bookId: current.bookId, chapterId: current.chapterId)
    }

    @discardableResult
    private func load(bookId: Int64, chapterId: Int64) async -> Bool {
        phase = .loading("加载正文…")
        do {
            let loaded = try await session.chapter(bookId: bookId, chapterId: chapterId)
            chapter = loaded
            input = "https://www.qidian.com/chapter/\(bookId)/\(chapterId)/"
            phase = .idle
            return true
        } catch {
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

