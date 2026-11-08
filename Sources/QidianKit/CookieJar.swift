import Foundation

/// 与 HTTPCookie 互转、可持久化的 Cookie 容器。
///
/// 起点登录态最关键的是三个 Cookie：
/// `ywkey`（会话票据）、`ywopenid`（用户标识）、`ywguid`（设备/用户 GUID），
/// 另外 `_csrfToken` 会同时出现在 Cookie 和每个 webcommon 请求的 query 里。
public struct CookieJar: Codable, Sendable {
    public struct Item: Codable, Sendable, Hashable {
        public var name: String
        public var value: String
        public var domain: String
        public var path: String
        public var expires: Date?
        public var secure: Bool
        public var httpOnly: Bool

        public init(name: String, value: String, domain: String, path: String = "/",
                    expires: Date? = nil, secure: Bool = true, httpOnly: Bool = false) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.expires = expires
            self.secure = secure
            self.httpOnly = httpOnly
        }

        public var httpCookie: HTTPCookie? {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if let expires { props[.expires] = expires }
            if secure { props[.secure] = "TRUE" }
            return HTTPCookie(properties: props)
        }
    }

    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    public init(cookies: [HTTPCookie]) {
        self.items = cookies.map {
            Item(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                 expires: $0.expiresDate, secure: $0.isSecure, httpOnly: $0.isHTTPOnly)
        }
    }

    public var httpCookies: [HTTPCookie] { items.compactMap(\.httpCookie) }

    /// 发给 m.qidian.com 的 `Cookie` 头。
    public var header: String {
        items.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public func value(named name: String) -> String? {
        items.last(where: { $0.name == name })?.value
    }

    public var csrfToken: String? { value(named: "_csrfToken") }
    public var isLoggedIn: Bool { (value(named: "ywkey")?.isEmpty == false) }

    /// 合并同名 Cookie（后者覆盖前者）。
    public mutating func merge(_ other: CookieJar) {
        for item in other.items {
            if let idx = items.firstIndex(where: { $0.name == item.name && $0.domain == item.domain && $0.path == item.path }) {
                items[idx] = item
            } else {
                items.append(item)
            }
        }
    }

    // MARK: Persistence

    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
        // 登录票据等同于密码，只允许当前用户读写。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    public static func load(from url: URL) throws -> CookieJar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CookieJar.self, from: Data(contentsOf: url))
    }

    /// 默认路径：`~/.qidian/cookies.json`，可用环境变量 `QIDIAN_COOKIES` 覆盖。
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["QIDIAN_COOKIES"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qidian/cookies.json")
    }
}
