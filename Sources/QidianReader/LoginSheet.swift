import SwiftUI
import WebKit
import QidianKit

/// 应用内登录：SwiftUI sheet + WKWebView。
///
/// 之前用独立的 NSWindow 承载登录页，登录成功后 close + 释放，
/// 会在关闭动画的 CA 事务里销毁窗口/WebKit 图层，触发
/// `_NSWindowTransformAnimation dealloc` 崩溃。
/// 改成 sheet 后，窗口生命周期完全交给 SwiftUI/AppKit 管理。
struct LoginSheet: View {
    let onFinish: ([HTTPCookie]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var finished = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("登录起点").font(.headline)
                Spacer()
                Text("登录成功后会自动关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            LoginWebView { cookies in
                guard !finished else { return }
                finished = true
                onFinish(cookies)
                dismiss()
            }
        }
        .frame(minWidth: 430, minHeight: 720)
    }
}

struct LoginWebView: NSViewRepresentable {
    let onLogin: ([HTTPCookie]) -> Void

    /// 进程内复用一个 WKWebView：sheet 关闭时只从视图层级移除，
    /// 不销毁 WebKit 视图（避免在 CA 事务里 dealloc 图层导致崩溃）。
    private static var sharedWebView: WKWebView?

    func makeCoordinator() -> Coordinator {
        Coordinator(onLogin: onLogin)
    }

    func makeNSView(context: Context) -> WKWebView {
        let web: WKWebView
        if let existing = Self.sharedWebView {
            web = existing
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            web = WKWebView(frame: .zero, configuration: config)
            Self.sharedWebView = web
        }

        web.customUserAgent = QidianClient.mobileUserAgent
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: URL(string: "https://m.qidian.com/")!))
        context.coordinator.startPolling(web)
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
        webView.navigationDelegate = nil
        // 故意不 stopLoading / 不置空 sharedWebView：交给复用的对象池。
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLogin: ([HTTPCookie]) -> Void
        private var timer: Timer?
        private var fired = false

        init(onLogin: @escaping ([HTTPCookie]) -> Void) {
            self.onLogin = onLogin
        }

        func startPolling(_ webView: WKWebView) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView, !self.fired else { return }
                Task { @MainActor in
                    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    guard cookies.contains(where: { $0.name == "ywkey" && !$0.value.isEmpty }) else { return }
                    self.fired = true
                    self.stopPolling()
                    self.onLogin(cookies)
                }
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        deinit {
            timer?.invalidate()
        }
    }
}
