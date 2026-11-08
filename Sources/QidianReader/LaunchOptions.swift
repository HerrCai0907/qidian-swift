import Foundation

/// 启动参数。`swift run QidianReader --no-activate` 或在 Xcode Scheme 里
/// 给 QidianReader 传 `--no-activate` 都生效。
struct LaunchOptions {
    /// 启动时不激活、不置顶窗口：窗口照常创建，但留在其他窗口后面。
    static let noActivateFlag = "--no-activate"

    /// 进程启动时解析一次，供 `AppDelegate` 使用。
    static let current = LaunchOptions(arguments: CommandLine.arguments)

    /// 是否禁止启动时抢焦点（默认 `false`，保持原来的“启动即前台”行为）。
    let suppressesForeground: Bool

    init(arguments: [String]) {
        suppressesForeground = Self.isEnabled(flag: Self.noActivateFlag,
                                              in: arguments.dropFirst())
    }

    /// 支持 `--no-activate`、`--no-activate=1`（`true` / `yes` / `on` 同理）；
    /// `--no-activate=0`（`false` / `no` / `off`）显式关闭。
    static func isEnabled<S: Sequence>(flag: String, in arguments: S) -> Bool
    where S.Element == String {
        for argument in arguments {
            if argument == flag {
                return true
            }
            guard argument.hasPrefix(flag + "=") else { continue }
            switch argument.dropFirst(flag.count + 1).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                continue
            }
        }
        return false
    }
}
