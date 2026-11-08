import Foundation

/// 起点移动站（m.qidian.com）的只读客户端，只保留阅读所需的最小接口：
///
/// - `GET /webcommon/chapter/getMChapterInfo?bookId=&chapterId=&_csrfToken=`
/// - `GET /webcommon/book/mCategory?bookId=&_csrfToken=`（全书目录）
///
/// 已购 VIP 章节的 `content` 是密文，需要 `WebChapterFetcher` 用 WebKit 解密。
public final class QidianClient: @unchecked Sendable {
    public static let baseURL = URL(string: "https://m.qidian.com")!
    public static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private let session: URLSession
    private let lock = NSLock()
    private var jar: CookieJar
    private var lastRequestAt: Date = .distantPast
    private var didBootstrap = false

    /// 相邻请求的最小间隔，避免触发风控。
    public var minimumRequestInterval: TimeInterval = 0.35

    /// 设置后，Cookie 变化（例如 `_csrfToken` 轮换）会自动回写磁盘。
    public var persistenceURL: URL?

    public init(cookies: CookieJar = CookieJar()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        jar = cookies
    }

    public convenience init(cookieFile: URL = CookieJar.defaultURL) {
        let jar = (try? CookieJar.load(from: cookieFile)) ?? CookieJar()
        self.init(cookies: jar)
    }

    public var cookies: CookieJar {
        lock.lock(); defer { lock.unlock() }
        return jar
    }

    public var isLoggedIn: Bool { cookies.isLoggedIn }

    public func updateCookies(_ newValue: CookieJar) {
        lock.lock()
        let before = jar.items
        jar.merge(newValue)
        let changed = jar.items != before
        let snapshot = jar
        let url = persistenceURL
        lock.unlock()

        if changed, let url {
            try? snapshot.save(to: url)
        }
    }

    // MARK: - Chapter

    /// 章节信息。已购 VIP 章节的 `content` 是密文，需配合 `fkp` 用 Fock 解密。
    public func chapter(bookId: Int64, chapterId: Int64) async throws -> ChapterData {
        // 必须先拿到 _csrfToken 再拼 URL。
        if jar.csrfToken == nil {
            try await bootstrap(bookId: bookId)
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "bookId", value: String(bookId)),
            URLQueryItem(name: "chapterId", value: String(chapterId)),
        ]
        if let token = cookies.csrfToken {
            items.append(URLQueryItem(name: "_csrfToken", value: token))
        }
        guard var comps = URLComponents(string: "https://m.qidian.com/webcommon/chapter/getMChapterInfo") else {
            throw QidianError.parse("bad url")
        }
        comps.queryItems = items
        guard let url = comps.url else { throw QidianError.parse("bad url") }

        let (data, _) = try await request(url: url, bootstrapBookId: bookId)
        let envelope: APIEnvelope<ChapterData>
        do {
            envelope = try JSONDecoder().decode(APIEnvelope<ChapterData>.self, from: data)
        } catch {
            throw QidianError.parse("JSON 解码失败: \(error)")
        }
        guard envelope.isOK, let chapter = envelope.data else {
            throw QidianError.api(code: envelope.code, message: envelope.msg ?? "getMChapterInfo failed")
        }
        return chapter
    }

    // MARK: - Catalog

    /// 全书目录（按卷分组）。一次请求返回整本书，适合在功能菜单里做章节选择。
    public func catalog(bookId: Int64) async throws -> BookCatalog {
        if jar.csrfToken == nil {
            try await bootstrap(bookId: bookId)
        }

        var items: [URLQueryItem] = [URLQueryItem(name: "bookId", value: String(bookId))]
        if let token = cookies.csrfToken {
            items.append(URLQueryItem(name: "_csrfToken", value: token))
        }
        guard var comps = URLComponents(string: "https://m.qidian.com/webcommon/book/mCategory") else {
            throw QidianError.parse("bad url")
        }
        comps.queryItems = items
        guard let url = comps.url else { throw QidianError.parse("bad url") }

        let (data, _) = try await request(url: url, bootstrapBookId: bookId)
        let envelope: APIEnvelope<BookCatalog>
        do {
            envelope = try JSONDecoder().decode(APIEnvelope<BookCatalog>.self, from: data)
        } catch {
            throw QidianError.parse("目录 JSON 解码失败: \(error)")
        }
        guard envelope.isOK, let catalog = envelope.data, !catalog.isEmpty else {
            throw QidianError.api(code: envelope.code, message: envelope.msg ?? "mCategory failed")
        }
        return catalog
    }

    /// 把接口返回的 `content` 转成段落；密文时返回 `isEncrypted = true`。
    public func content(of data: ChapterData) -> ChapterContent {
        let info = data.chapterInfo
        if ChapterHTMLParser.looksEncrypted(info.content, fkp: info.fkp) {
            return ChapterContent(paragraphs: [], isEncrypted: true)
        }
        return ChapterContent(paragraphs: ChapterHTMLParser.paragraphs(from: info.content),
                              isEncrypted: false)
    }

    // MARK: - Session bootstrap

    /// 全新会话直接调接口会 403：先访问一次书籍页拿到 `_csrfToken` 等基础 Cookie。
    public func bootstrap(bookId: Int64, force: Bool = false) async throws {
        if didBootstrap && !force { return }
        try await throttle()

        guard let url = URL(string: "https://m.qidian.com/book/\(bookId)/") else {
            throw QidianError.parse("bad url")
        }
        var req = URLRequest(url: url)
        req.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let header = cookies.header
        if !header.isEmpty { req.setValue(header, forHTTPHeaderField: "Cookie") }

        let (_, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            absorbSetCookies(from: http, url: url)
        }
        didBootstrap = jar.csrfToken != nil
    }

    // MARK: - Transport

    private func request(url: URL, attempt: Int = 0,
                         bootstrapBookId: Int64? = nil) async throws -> (Data, HTTPURLResponse) {
        try await throttle()

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Self.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("application/json,text/html;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("https://m.qidian.com/", forHTTPHeaderField: "Referer")
        let header = cookies.header
        if !header.isEmpty {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw QidianError.parse("非 HTTP 响应")
        }
        absorbSetCookies(from: http, url: url)

        // 202 = 腾讯 WAF 的 JS 挑战页；重试无意义，直接报风控。
        if http.statusCode == 202 {
            throw QidianError.riskControl
        }
        if http.statusCode == 403, attempt == 0, !didBootstrap, let bootstrapBookId {
            try await bootstrap(bookId: bootstrapBookId, force: true)
            return try await request(url: url, attempt: attempt + 1, bootstrapBookId: bootstrapBookId)
        }
        if http.statusCode == 429 || (500...599).contains(http.statusCode) {
            if attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(1.2 * Double(attempt + 1) * 1_000_000_000))
                return try await request(url: url, attempt: attempt + 1, bootstrapBookId: bootstrapBookId)
            }
            throw QidianError.http(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QidianError.http(http.statusCode)
        }
        return (data, http)
    }

    /// 解析 `Set-Cookie`。URLSession 会把多个 Set-Cookie 用 ", " 合并，
    /// 但 Expires 里也含逗号，因此只在“, 后面紧跟 name=”处切分。
    private func absorbSetCookies(from response: HTTPURLResponse, url: URL) {
        guard let raw = response.allHeaderFields["Set-Cookie"] as? String, !raw.isEmpty else { return }
        let split = raw.replacingOccurrences(of: ",(?=\\s*[A-Za-z0-9_\\-]+=)",
                                             with: "\n",
                                             options: .regularExpression)
        var fresh: [HTTPCookie] = []
        for line in split.split(separator: "\n") {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": String(line)], for: url)
            fresh.append(contentsOf: cookies)
        }
        guard !fresh.isEmpty else { return }
        var updated = cookies
        updated.merge(CookieJar(cookies: fresh))
        updateCookies(updated)
    }

    private func throttle() async throws {
        lock.lock()
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        let wait = max(0, minimumRequestInterval - elapsed)
        lastRequestAt = Date().addingTimeInterval(wait)
        lock.unlock()
        if wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}
