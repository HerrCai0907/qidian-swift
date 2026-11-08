import XCTest
@testable import QidianKit

final class QidianKitTests: XCTestCase {
    func testParagraphParsingHandlesUnclosedP() {
        let html = "<p>　　第一段<p>　　第二段<br>第三段</p>"
        XCTAssertEqual(ChapterHTMLParser.paragraphs(from: html), ["第一段", "第二段", "第三段"])
    }

    func testEntityDecoding() {
        let html = "<p>他说：&ldquo;你好&rdquo; &amp; 再见&#33;&#x4F60;</p>"
        XCTAssertEqual(ChapterHTMLParser.paragraphs(from: html).first, "他说：“你好” & 再见!你")
    }

    func testEncryptedDetection() {
        let cipher = String(repeating: "QUJDREVGRw==", count: 10)
        XCTAssertTrue(ChapterHTMLParser.looksEncrypted(cipher, fkp: "d2luZG93Lm9ua2V5Zm9jdXMo"))
        XCTAssertFalse(ChapterHTMLParser.looksEncrypted("<p>正文</p>", fkp: "abc"))
        XCTAssertFalse(ChapterHTMLParser.looksEncrypted(cipher, fkp: nil))
    }

    func testCookieJarHeaderAndCSRF() {
        var jar = CookieJar()
        jar.items = [
            .init(name: "ywkey", value: "abc", domain: ".qidian.com"),
            .init(name: "_csrfToken", value: "tok-1", domain: ".qidian.com"),
        ]
        XCTAssertTrue(jar.isLoggedIn)
        XCTAssertEqual(jar.csrfToken, "tok-1")
        XCTAssertEqual(jar.header, "ywkey=abc; _csrfToken=tok-1")
        XCTAssertEqual(jar.httpCookies.count, 2)
    }

    func testChapterDecoding() throws {
        let json = """
        {"code":0,"data":{"isLogin":1,"chapterInfo":{
        "chapterId":2,"chapterName":"第二章","content":"jA1ImDUt","fkp":"d2lu",
        "isBuy":1,"price":0,"wordsCount":3000,"prev":1,"next":3,
        "extra":{"volumeName":"卷","prevName":"第一章","nextName":"第三章"}}}}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<ChapterData>.self, from: json)
        let data = try XCTUnwrap(envelope.data)
        XCTAssertTrue(data.loggedIn)
        XCTAssertEqual(data.chapterInfo.volumeName, "卷")
        XCTAssertEqual(data.chapterInfo.next, 3)
        XCTAssertTrue(ChapterHTMLParser.looksEncrypted(data.chapterInfo.content, fkp: data.chapterInfo.fkp))
    }

    func testChapterReferenceParsing() {
        XCTAssertEqual(ChapterRef("https://www.qidian.com/chapter/1037095853/801714441/"),
                       ChapterRef(bookId: 1037095853, chapterId: 801714441))
        XCTAssertEqual(ChapterRef("https://m.qidian.com/chapter/1037095853/801714441/?source=pc_jump"),
                       ChapterRef(bookId: 1037095853, chapterId: 801714441))
        XCTAssertEqual(ChapterRef("1037095853 801714441"),
                       ChapterRef(bookId: 1037095853, chapterId: 801714441))
        XCTAssertEqual(ChapterRef("1037095853/801714441"),
                       ChapterRef(bookId: 1037095853, chapterId: 801714441))
        XCTAssertNil(ChapterRef("随便一段文字"))
        XCTAssertNil(ChapterRef(""))
    }

    // MARK: - Local chapter cache

    func testChapterCacheRoundTripUsesBookNameDirectory() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = ChapterCache(root: root)
        let chapter = makeChapter()
        let url = try XCTUnwrap(cache.save(chapter))

        let bookDirectory = root.appendingPathComponent("牧者密续", isDirectory: true)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       bookDirectory.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bookDirectory.appendingPathComponent(ChapterCache.metadataFileName).path))

        // 重新建一个实例，验证能从磁盘扫描到书目录。
        let reopened = ChapterCache(root: root)
        let restored = try XCTUnwrap(reopened.load(bookId: 1037095853, chapterId: 801714441))
        XCTAssertEqual(restored.paragraphs, ["第一段", "第二段"])
        XCTAssertEqual(restored.title, "第三百五十七章 法之书的进化")
        XCTAssertEqual(restored.nextId, 801810226)
        XCTAssertTrue(restored.isFromCache)
        XCTAssertFalse(restored.isPreview)
        XCTAssertTrue(reopened.isCached(bookId: 1037095853, chapterId: 801714441))
        XCTAssertEqual(reopened.cachedChapterIds(bookId: 1037095853), [801714441])
    }

    func testChapterCacheSkipsPreviewAndEmptyContent() {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = ChapterCache(root: root)
        XCTAssertNil(cache.save(makeChapter(isPreview: true)))
        XCTAssertNil(cache.save(makeChapter(paragraphs: [])))
        XCTAssertFalse(cache.isCached(bookId: 1037095853, chapterId: 801714441))
    }

    func testChapterCacheSanitizesFolderNameAndSeparatesSameTitleBooks() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = ChapterCache(root: root)
        let first = makeChapter(bookId: 1, bookName: "牧者/密续: 上", chapterId: 10)
        let second = makeChapter(bookId: 2, bookName: "牧者/密续: 上", chapterId: 20)
        XCTAssertNotNil(cache.save(first))
        XCTAssertNotNil(cache.save(second))

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.allSatisfy { !$0.contains("/") && !$0.contains(":") })

        XCTAssertEqual(cache.load(bookId: 1, chapterId: 10)?.bookId, 1)
        XCTAssertEqual(cache.load(bookId: 2, chapterId: 20)?.bookId, 2)
        XCTAssertNil(cache.load(bookId: 1, chapterId: 20))
    }

    // MARK: - Helpers

    private func temporaryCacheRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qidian-cache-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeChapter(bookId: Int64 = 1037095853,
                             bookName: String = "牧者密续",
                             chapterId: Int64 = 801714441,
                             paragraphs: [String] = ["第一段", "第二段"],
                             isPreview: Bool = false) -> LoadedChapter {
        LoadedChapter(
            chapterId: chapterId,
            bookId: bookId,
            bookName: bookName,
            authorName: "不祈十弦",
            title: "第三百五十七章 法之书的进化",
            volumeName: "喰主之钥",
            paragraphs: paragraphs,
            prevId: 801550399,
            nextId: 801810226,
            prevName: "第三百五十六章 大罪卡：狂猎之王",
            nextName: "第三百五十八章 冬天司的诞生",
            wordsCount: 5178,
            authorSay: nil,
            decryptedByWeb: false,
            isPreview: isPreview,
            isFromCache: false
        )
    }
}
