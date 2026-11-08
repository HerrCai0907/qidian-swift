import Foundation

/// 把起点返回的正文 HTML 拆成段落。
///
/// 免费章节形如：`<p>　　第一段<p>　　第二段`
/// 页面 DOM 中形如：`<span class="content-text" data-index="1">　　第一段</span>`
public enum ChapterHTMLParser {
    public static func paragraphs(from html: String) -> [String] {
        var s = html
        guard !s.isEmpty else { return [] }

        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<p[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</div\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)

        return s
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 判断接口返回的 `content` 是不是密文。
    ///
    /// 免费章节是 HTML；已购 VIP 章节是纯 Base64，并带有 `fkp` 密钥池。
    public static func looksEncrypted(_ content: String, fkp: String?) -> Bool {
        guard let fkp, !fkp.isEmpty else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("<") else { return false }
        let base64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return trimmed.unicodeScalars.allSatisfy { base64.contains($0) }
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&mdash;": "—",
            "&hellip;": "…", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }

        let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);")
        guard let regex else { return out }
        let ns = out as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var token = ns.substring(with: match.range(at: 1))
            let radix = token.hasPrefix("x") || token.hasPrefix("X") ? 16 : 10
            if radix == 16 { token.removeFirst() }
            if let value = UInt32(token, radix: radix), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
