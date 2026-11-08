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
}
