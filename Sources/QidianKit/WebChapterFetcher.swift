import Foundation

#if canImport(WebKit)
import WebKit
#if canImport(AppKit)
import AppKit
#endif

/// VIP 章节正文的兜底加载器。
///
/// 已购买的章节，`getMChapterInfo` 返回的 `content` 是 Base64 密文，
/// 需要页面里的 WebAssembly 模块（`window.Fock`）配合 `fkp` 密钥池解密。
/// 直接移植该模块成本高且易随版本失效，因此这里用离屏 `WKWebView`
/// 复用官方前端完成解密，再从 DOM 读取 `span.content-text`。
///
/// 注意：WKWebView 只在首次使用时创建并**一直复用**，不在每次加载后释放。
/// 在 CA 事务进行中销毁带图层的 WebKit 视图容易触发
/// `_NSWindowTransformAnimation` / `objc_release` 一类崩溃。
@MainActor
public final class WebChapterFetcher {
    public static let shared = WebChapterFetcher()

    /// 非持久化数据存储，避免污染用户浏览数据；进程内复用。
    private var webView: WKWebView?

    /// 离屏 WebView 是单实例，必须串行使用：否则自动预取与用户翻页
    /// 同时进行时，后一次 `load` 会打断前一次，读到错误的章节 DOM。
    private var isFetching = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func fetch(bookId: Int64,
                      chapterId: Int64,
                      cookies: CookieJar,
                      timeout: TimeInterval = 20) async throws -> [String] {
        await acquireWebView()
        defer { releaseWebView() }

        #if canImport(AppKit)
        _ = NSApplication.shared
        #endif

        let web = webView ?? makeWebView()
        webView = web

        let store = web.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies.httpCookies {
            await store.setCookie(cookie)
        }

        let url = URL(string: "https://m.qidian.com/chapter/\(bookId)/\(chapterId)/")!
        web.stopLoading()
        web.load(URLRequest(url: url))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let paragraphs = try? await extractParagraphs(from: web, chapterId: chapterId),
               !paragraphs.isEmpty {
                return paragraphs
            }
        }
        throw QidianError.timeout
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: config)
        web.customUserAgent = QidianClient.mobileUserAgent
        return web
    }

    private func acquireWebView() async {
        if !isFetching {
            isFetching = true
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    private func releaseWebView() {
        if waiting.isEmpty {
            isFetching = false
        } else {
            // 所有权直接转交给下一个等待者，isFetching 保持 true。
            waiting.removeFirst().resume()
        }
    }

    private func extractParagraphs(from web: WKWebView, chapterId: Int64) async throws -> [String] {
        let js = """
        (() => {
          const main = document.querySelector('main#c-\(chapterId)')
                    || document.querySelector('main.content');
          if (!main) return null;
          const spans = [...main.querySelectorAll('span.content-text')]
              .map(e => (e.textContent || '').trim()).filter(Boolean);
          if (spans.length) return spans;
          const ps = [...main.querySelectorAll('p')]
              .map(e => (e.textContent || '').trim()).filter(Boolean);
          return ps.length ? ps : null;
        })()
        """
        let value = try await web.evaluateJavaScript(js)
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? String }
    }
}
#endif
