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

    func testBookReferenceParsing() {
        XCTAssertEqual(BookRef("https://www.qidian.com/book/1037095853/")?.bookId, 1037095853)
        XCTAssertEqual(BookRef("https://m.qidian.com/book/1037095853/?source=pc_jump")?.bookId, 1037095853)
        XCTAssertEqual(BookRef("1037095853")?.bookId, 1037095853)
        XCTAssertNil(BookRef(""))
        XCTAssertNil(BookRef("随便一段文字"))
        XCTAssertNil(BookRef("0"))
        XCTAssertNil(BookRef("1037095853 801714441"))
    }

    // MARK: - Catalog

    func testCatalogDecodingAndLookup() throws {
        let json = """
        {"code":0,"data":{
        "bookId":1037095853,"bookName":"牧者密续","chapterTotalCnt":2,
        "bookStatus":"完本","limitFreeType":3,"salesMode":1,
        "vs":[
          {"vId":109516838,"vN":"玻璃台阶","cCnt":1,"wC":242664,
           "cs":[{"id":753919666,"cN":"第一章 你是来逮捕我的吗","cnt":3659,
                  "uT":"2023-05-21 07:33:10","sS":1,"uuid":1}]},
          {"vId":109516839,"vN":"","cCnt":1,"wC":1000,
           "cs":[{"id":753919667,"cN":"","cnt":0,"uT":"","sS":0,"uuid":2}]}
        ]}}
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(APIEnvelope<BookCatalog>.self, from: json)
        let catalog = try XCTUnwrap(envelope.data)
        XCTAssertTrue(envelope.isOK)
        XCTAssertEqual(catalog.bookId, 1037095853)
        XCTAssertEqual(catalog.bookName, "牧者密续")
        XCTAssertEqual(catalog.bookStatus, "完本")
        XCTAssertEqual(catalog.volumes.count, 2)
        XCTAssertEqual(catalog.chapterCount, 2)
        XCTAssertFalse(catalog.isEmpty)

        XCTAssertEqual(catalog.volumes[0].displayName, "玻璃台阶")
        XCTAssertEqual(catalog.volumes[1].displayName, "正文")
        XCTAssertEqual(catalog.allChapters.map(\.chapterId), [753919666, 753919667])
        XCTAssertTrue(catalog.allChapters[0].isPaid)
        XCTAssertFalse(catalog.allChapters[1].isPaid)
        XCTAssertEqual(catalog.allChapters[1].displayTitle, "章节 753919667")
        XCTAssertEqual(catalog.allChapters[1].uuid, 2)

        XCTAssertEqual(catalog.chapter(withId: 753919667)?.uuid, 2)
        XCTAssertEqual(catalog.volume(containing: 753919667)?.volumeId, 109516839)
        XCTAssertNil(catalog.chapter(withId: 42))
    }

    func testCatalogChapterCountFallsBackToDeclaredTotal() throws {
        // 卷里没有章节（接口只给了 cCnt）时，用 chapterTotalCnt。
        let catalog = BookCatalog(
            bookId: 1,
            bookName: "书",
            chapterTotalCnt: 1373,
            volumes: [CatalogVolume(volumeId: 10, name: "卷", declaredChapterCount: 1373, chapters: [])]
        )
        XCTAssertEqual(catalog.chapterCount, 1373)
        XCTAssertTrue(catalog.isEmpty)
    }

    func testCatalogChapterCountPrefersActualChapters() throws {
        let catalog = BookCatalog(
            bookId: 1,
            bookName: "书",
            chapterTotalCnt: 1373,
            volumes: [CatalogVolume(volumeId: 10, name: "卷", declaredChapterCount: 99, chapters: [
                CatalogChapter(chapterId: 100, title: "第一章"),
            ])]
        )
        XCTAssertEqual(catalog.chapterCount, 1)
        XCTAssertFalse(catalog.isEmpty)
    }

    func testCatalogSearchMatchesTitle() throws {
        let catalog = BookCatalog(
            bookId: 1,
            bookName: "书",
            chapterTotalCnt: 2,
            volumes: [
                CatalogVolume(volumeId: 10, name: "第一卷", chapters: [
                    CatalogChapter(chapterId: 100, title: "第一章 开始", wordCount: 100, uuid: 900),
                    CatalogChapter(chapterId: 101, title: "第二章 风起", wordCount: 200, uuid: 2),
                ])
            ]
        )

        XCTAssertEqual(catalog.chapters(matching: "").count, 2)
        XCTAssertEqual(catalog.chapters(matching: "开始").map(\.chapterId), [100])
        XCTAssertEqual(catalog.chapters(matching: "风起").map(\.chapterId), [101])
        XCTAssertTrue(catalog.chapters(matching: "不存在").isEmpty)
        XCTAssertTrue(catalog.chapters(matching: "900").isEmpty)
    }

    func testCatalogToleratesMissingCollections() throws {
        let json = """
        {"code":0,"data":{"bookId":9,"bookName":"只有书","vs":[{"vId":1,"vN":"卷"}]}}
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(APIEnvelope<BookCatalog>.self, from: json)
        let catalog = try XCTUnwrap(envelope.data)
        XCTAssertEqual(catalog.bookId, 9)
        XCTAssertEqual(catalog.volumes.count, 1)
        XCTAssertTrue(catalog.volumes[0].chapters.isEmpty)
        XCTAssertTrue(catalog.isEmpty)
    }

    // MARK: - Whole-book background download

    func testWholeBookDownloadPlanStartsAtCurrentChapterAndWrapsAround() {
        let catalog = makeCatalog(chapterIds: [10, 20, 30, 40, 50])
        let plan = WholeBookDownloadPlan(catalog: catalog,
                                         cachedChapterIds: [20],
                                         startingAt: 30)

        XCTAssertEqual(plan.totalChapters, 5)
        XCTAssertEqual(plan.cachedChapters, 1)
        XCTAssertEqual(plan.unavailableChapters, 0)
        XCTAssertEqual(plan.chapters.map(\.chapterId), [30, 40, 50, 10])
    }

    func testWholeBookDownloadPlanSkipsKnownUnavailableAndUnknownStart() {
        let catalog = makeCatalog(chapterIds: [10, 20, 30, 40, 50])
        let plan = WholeBookDownloadPlan(catalog: catalog,
                                         cachedChapterIds: [40],
                                         unavailableChapterIds: [10, 30],
                                         startingAt: 999)

        // 起跑章不在目录里时从第一章开始。
        XCTAssertEqual(plan.chapters.map(\.chapterId), [20, 50])
        XCTAssertEqual(plan.cachedChapters, 1)
        XCTAssertEqual(plan.unavailableChapters, 2)
    }

    func testWholeBookDownloadPlanIsEmptyWhenEverythingCached() {
        let catalog = makeCatalog(chapterIds: [10, 20, 30])
        let plan = WholeBookDownloadPlan(catalog: catalog,
                                         cachedChapterIds: [10, 20, 30],
                                         startingAt: 20)

        XCTAssertTrue(plan.chapters.isEmpty)
        XCTAssertEqual(plan.totalChapters, 3)
        XCTAssertEqual(plan.cachedChapters, 3)
    }

    func testWholeBookDownloadPlanDropsDuplicateAndInvalidChapters() {
        let catalog = makeCatalog(chapterIds: [10, 10, 0, 20])
        let plan = WholeBookDownloadPlan(catalog: catalog, cachedChapterIds: [])

        XCTAssertEqual(plan.totalChapters, 2)
        XCTAssertEqual(plan.chapters.map(\.chapterId), [10, 20])
    }

    func testBookDownloadPacingUsesOnePlusOneRandomMinute() {
        XCTAssertEqual(BookDownloadPacing.interval(randomValue: 0), 60, accuracy: 0.0001)
        XCTAssertEqual(BookDownloadPacing.interval(randomValue: 0.25), 75, accuracy: 0.0001)
        XCTAssertEqual(BookDownloadPacing.interval(randomValue: 0.5), 90, accuracy: 0.0001)
        XCTAssertEqual(BookDownloadPacing.interval(randomValue: 1), 120, accuracy: 0.0001)
        XCTAssertEqual(BookDownloadPacing.interval(randomValue: -1), 60, accuracy: 0.0001)
        XCTAssertEqual(BookDownloadPacing.interval(randomValue: 2), 120, accuracy: 0.0001)
    }

    func testBookDownloadPacingNextIntervalStaysInRange() {
        for _ in 0..<200 {
            let interval = BookDownloadPacing.nextInterval()
            XCTAssertGreaterThanOrEqual(interval, 60)
            XCTAssertLessThan(interval, 120)
        }
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

    // MARK: - Reading history

    func testReadingHistoryPersistsLatestPerBook() throws {
        let url = temporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ReadingHistoryStore(url: url)
        let base = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(store.record(bookId: 1, chapterId: 10, bookName: "书一",
                                   chapterTitle: "第一章", anchor: -80, at: base))
        XCTAssertTrue(store.record(bookId: 2, chapterId: 20, bookName: "书二",
                                   chapterTitle: "第二章", anchor: 200,
                                   at: base.addingTimeInterval(10)))
        XCTAssertTrue(store.record(bookId: 1, chapterId: 11, bookName: "书一",
                                   chapterTitle: "第二章", anchor: 300,
                                   at: base.addingTimeInterval(20)))

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.lastEntry?.bookId, 1)
        XCTAssertEqual(store.lastEntry?.chapterId, 11)
        XCTAssertEqual(store.entry(forBookId: 1)?.anchor, 300)

        let reloaded = ReadingHistoryStore(url: url)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.lastEntry?.chapterId, 11)
        XCTAssertEqual(reloaded.entry(forBookId: 2)?.chapterId, 20)
    }

    func testReadingHistorySkipsSamePositionAndMovesBookToFront() throws {
        let url = temporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ReadingHistoryStore(url: url)
        let base = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(store.record(bookId: 1, chapterId: 10, bookName: "书一",
                                   chapterTitle: "第一章", anchor: 10, at: base))
        XCTAssertFalse(store.record(bookId: 1, chapterId: 10, bookName: "书一",
                                    chapterTitle: "第一章", anchor: 10,
                                    at: base.addingTimeInterval(10)))

        XCTAssertTrue(store.record(bookId: 2, chapterId: 20, bookName: "书二",
                                   chapterTitle: "第二章", anchor: 20,
                                   at: base.addingTimeInterval(20)))
        XCTAssertTrue(store.record(bookId: 1, chapterId: 11, bookName: "书一",
                                   chapterTitle: "第二章", anchor: 50,
                                   at: base.addingTimeInterval(30)))

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.lastEntry?.bookId, 1)
        XCTAssertEqual(store.lastEntry?.chapterId, 11)
        XCTAssertEqual(store.entry(forBookId: 1)?.anchor, 50)
    }

    // MARK: - Helpers

    private func temporaryCacheRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qidian-cache-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func temporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qidian-history-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(ReadingHistoryStore.fileName)
    }

    private func makeCatalog(chapterIds: [Int64]) -> BookCatalog {
        BookCatalog(
            bookId: 1037095853,
            bookName: "牧者密续",
            chapterTotalCnt: chapterIds.count,
            volumes: [
                CatalogVolume(volumeId: 1, name: "正文", chapters: chapterIds.enumerated().map { index, id in
                    CatalogChapter(chapterId: id,
                                   title: "第 \(index + 1) 章",
                                   wordCount: 100,
                                   uuid: index + 1)
                })
            ]
        )
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
