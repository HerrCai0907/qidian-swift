import Foundation
import QidianKit
#if canImport(AppKit)
import AppKit
#endif

@main
struct QidianCLI {
    static func main() {
        // WebKit 需要完整的 AppKit 生命周期；统一走 NSApplication 事件循环。
        #if canImport(AppKit)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await dispatch(arguments: Array(CommandLine.arguments.dropFirst()))
            fflush(stdout); fflush(stderr)
            exit(code)
        }
        NSApp.run()
        #else
        Task { @MainActor in
            let code = await dispatch(arguments: Array(CommandLine.arguments.dropFirst()))
            fflush(stdout); fflush(stderr)
            exit(code)
        }
        dispatchMain()
        #endif
    }

    @MainActor
    static func dispatch(arguments: [String]) async -> Int32 {
        var args = arguments
        var cookieURL = CookieJar.defaultURL

        if let index = args.firstIndex(of: "--cookies"), index + 1 < args.count {
            cookieURL = URL(fileURLWithPath: (args[index + 1] as NSString).expandingTildeInPath)
            args.removeSubrange(index...(index + 1))
        }

        guard let command = args.first else {
            printHelp()
            return 0
        }
        let rest = Array(args.dropFirst())

        do {
            switch command {
            case "help", "-h", "--help":
                printHelp()
                return 0

            case "login":
                #if canImport(AppKit)
                return await runLogin(cookieURL: cookieURL)
                #else
                print("当前平台不支持图形登录")
                return 1
                #endif

            case "read":
                var allowWeb = true
                var prefetch = true
                var inputParts: [String] = []
                for part in rest {
                    if part == "--no-web" { allowWeb = false }
                    else if part == "--no-prefetch" { prefetch = false }
                    else { inputParts.append(part) }
                }
                let input = inputParts.joined(separator: " ")
                guard let ref = ChapterRef(input) else {
                    throw CLIError.usage(
                        "用法: qidian read <章节链接 | bookId chapterId> [--no-web] [--no-prefetch]")
                }

                let session = QidianReadingSession(cookieFile: cookieURL)
                session.allowsWebDecryption = allowWeb
                session.prefetchNextChapter = prefetch
                let chapter = try await session.open(ref)

                if chapter.isPreview {
                    FileHandle.standardError.write(
                        Data("⚠️ 未订阅，仅返回试读片段。登录并订阅后可读全文。\n".utf8))
                }
                if chapter.decryptedByWeb {
                    FileHandle.standardError.write(
                        Data("ℹ️ 密文正文已通过 WebKit + Fock 解出。\n".utf8))
                }
                if chapter.isFromCache {
                    let path = session.cachedFileURL(bookId: chapter.bookId,
                                                     chapterId: chapter.chapterId)?.path ?? "~/.qidian"
                    FileHandle.standardError.write(
                        Data("ℹ️ 已从本地缓存读取：\(path)\n".utf8))
                }

                print(render(chapter))

                // CLI 退出会把后台预取一起带走，这里等它落盘；GUI 里则不需要。
                if prefetch, let nextId = chapter.nextId, nextId > 0 {
                    await session.waitForPrefetch()
                    reportPrefetch(session: session,
                                   bookId: chapter.bookId,
                                   nextId: nextId,
                                   nextName: chapter.nextName)
                }
                return 0

            default:
                printHelp()
                return 1
            }
        } catch {
            FileHandle.standardError.write(Data("错误: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    @MainActor
    private static func runLogin(cookieURL: URL) async -> Int32 {
        let controller = QidianLoginWindowController()
        var saved = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.present { cookies in
                var jar = CookieJar(cookies: cookies)
                if let old = try? CookieJar.load(from: cookieURL) {
                    var merged = old
                    merged.merge(jar)
                    jar = merged
                }
                do {
                    try jar.save(to: cookieURL)
                    print("登录成功，Cookie 已保存到 \(cookieURL.path)")
                    saved = true
                } catch {
                    FileHandle.standardError.write(Data("保存 Cookie 失败: \(error)\n".utf8))
                }
                continuation.resume()
            }
        }
        return saved ? 0 : 1
    }

    private static func reportPrefetch(session: QidianReadingSession,
                                       bookId: Int64,
                                       nextId: Int64,
                                       nextName: String?) {
        let label = nextName.map { "《\($0)》" } ?? "下一章"
        switch session.prefetchOutcome(chapterId: nextId) {
        case .cached:
            let path = session.cachedFileURL(bookId: bookId, chapterId: nextId)?.path
                ?? "~/.qidian"
            FileHandle.standardError.write(
                Data("ℹ️ 已自动缓存\(label)：\(path)\n".utf8))
        case .ignoredNotPurchased:
            FileHandle.standardError.write(
                Data("ℹ️ \(label)未购买，已忽略自动缓存。\n".utf8))
        case .failed:
            // 后台预取失败不影响当前阅读，静默处理。
            break
        case nil:
            if let path = session.cachedFileURL(bookId: bookId, chapterId: nextId)?.path {
                FileHandle.standardError.write(
                    Data("ℹ️ \(label)已在本地缓存：\(path)\n".utf8))
            }
        }
    }

    private static func render(_ chapter: LoadedChapter) -> String {
        var out = ""
        if !chapter.bookName.isEmpty {
            out += "《\(chapter.bookName)》"
            if !chapter.authorName.isEmpty { out += "  \(chapter.authorName)" }
            out += "\n\n"
        }
        out += "# \(chapter.title)\n\n"
        var meta: [String] = []
        if let volume = chapter.volumeName { meta.append("卷：\(volume)") }
        meta.append("\(chapter.wordsCount) 字")
        if chapter.isPreview { meta.append("试读") }
        out += "> " + meta.joined(separator: " · ") + "\n\n"
        out += chapter.paragraphs.map { "　　" + $0 }.joined(separator: "\n\n")
        out += "\n"
        if let say = chapter.authorSay, !say.isEmpty {
            out += "\n---\n\n**作者说**\n\n\(say)\n"
        }
        return out
    }

    private static func printHelp() {
        print("""
        qidian — 起点阅读（登录 + 阅读）

        用法:
          qidian login
          qidian read <章节链接 | bookId chapterId> [--no-web] [--no-prefetch]

        示例:
          qidian login
          qidian read https://www.qidian.com/chapter/1037095853/801714441/
          qidian read 1037095853 801714441
          qidian read 1037095853 753919666 --no-web

        说明:
          · 免费章节直接由接口返回明文。
          · VIP 已购章节返回 Fock 密文，默认用离屏 WKWebView 解密；
            --no-web 时只调用接口。
          · 读完当前章后会自动在后台尝试缓存下一章；下一章未购买（只能试读）
            时按约定忽略。--no-prefetch 可关闭这个行为。
          · 下载过的完整章节按书名保存在 ~/.qidian/<书名>/<chapterId>.json，
            再次阅读同一章时优先读本地缓存。
          · Cookie 默认保存在 ~/.qidian/cookies.json，
            可用全局参数 --cookies <path> 指定；缓存根目录可用
            环境变量 QIDIAN_CACHE 覆盖。
        """)
    }
}

enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? {
        switch self {
        case .usage(let text): return text
        }
    }
}
