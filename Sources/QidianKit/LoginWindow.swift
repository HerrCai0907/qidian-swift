#if canImport(AppKit) && canImport(WebKit)
import AppKit
import WebKit

/// 弹出真实起点页面完成登录，登录成功后回传 Cookie。
///
/// 生命周期上刻意**不关闭、不释放**窗口：
/// NSWindow 默认 `isReleasedWhenClosed = true`，在 ARC 下 close 会被再释放一次，
/// 且关闭动画会在 CA 事务里销毁 WebKit 图层，表现为
/// `_NSWindowTransformAnimation dealloc` 崩溃。
/// 这里改成：隐藏 + 复用，窗口随控制器一直存活。
@MainActor
public final class QidianLoginWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var timer: Timer?
    private var completion: (([HTTPCookie]) -> Void)?
    private var didFinish = false

    public override init() { super.init() }

    public func present(completion: @escaping ([HTTPCookie]) -> Void) {
        self.completion = completion
        self.didFinish = false

        if let window, let webView {
            window.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            webView.load(URLRequest(url: URL(string: "https://m.qidian.com/")!))
            startPolling()
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 780), configuration: config)
        web.customUserAgent = QidianClient.mobileUserAgent

        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 430, height: 780),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "登录起点（登录成功后会自动隐藏）"
        win.contentView = web
        win.delegate = self
        // 关键：避免 ARC 下的双重释放与关闭动画。
        win.isReleasedWhenClosed = false
        win.animationBehavior = .none
        win.center()
        win.makeKeyAndOrderFront(nil)

        window = win
        webView = web

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        web.load(URLRequest(url: URL(string: "https://m.qidian.com/")!))
        startPolling()
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollCookies()
            }
        }
    }

    private func pollCookies() async {
        guard let webView, !didFinish else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard cookies.contains(where: { $0.name == "ywkey" && !$0.value.isEmpty }) else { return }

        didFinish = true
        timer?.invalidate()
        timer = nil

        let callback = completion
        completion = nil

        // 只隐藏，不 close：窗口与 WKWebView 继续存活，避免在 CA 事务中销毁图层。
        window?.orderOut(nil)
        callback?(cookies)
    }

    public func windowWillClose(_ notification: Notification) {
        // 用户手动点关闭：窗口由 isReleasedWhenClosed = false 保证不被释放，
        // 下次 present() 会复用。
        timer?.invalidate()
        timer = nil
    }
}
#endif
