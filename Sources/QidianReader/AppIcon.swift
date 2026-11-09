import AppKit

/// App 图标（黑白「起点」）。
///
/// `swift run` 直接运行裸可执行文件时没有 `.app` 包，也就没有 `Info.plist` 里的
/// `CFBundleIconFile`，Dock 默认会显示一个空白/终端图标。这里把 `.icns` 作为
/// SwiftPM 资源打包，启动时交给 `NSApplication.applicationIconImage`，
/// 让 Dock、Cmd-Tab 和「强制退出」面板都能显示同一个图标。
enum AppIcon {
    /// 1024×1024 的黑底白字「起点」，随可执行文件一起分发。
    static var image: NSImage? {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        return image
    }
}
