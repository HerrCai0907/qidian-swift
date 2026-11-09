import XCTest
import QidianKit
@testable import QidianReader

final class CatalogListLayoutTests: XCTestCase {
    // MARK: - Fixtures

    private func chapter(_ id: Int64, _ title: String) -> CatalogChapter {
        CatalogChapter(chapterId: id, title: title, wordCount: 3_000)
    }

    private func volume(_ id: Int64, _ name: String, _ chapters: [CatalogChapter]) -> CatalogVolume {
        CatalogVolume(volumeId: id,
                      name: name,
                      declaredChapterCount: chapters.count,
                      wordCount: chapters.count * 3_000,
                      chapters: chapters)
    }

    private func catalog(_ volumes: [CatalogVolume]) -> BookCatalog {
        BookCatalog(bookId: 42,
                    bookName: "测试书",
                    chapterTotalCnt: volumes.reduce(0) { $0 + $1.chapters.count },
                    volumes: volumes)
    }

    /// 两卷 3 + 2 章。
    private var twoVolumeCatalog: BookCatalog {
        catalog([
            volume(1, "第一卷", [chapter(101, "第一章 开始"), chapter(102, "第二章"), chapter(103, "第三章")]),
            volume(2, "第二卷", [chapter(201, "第四章"), chapter(202, "第五章")]),
        ])
    }

    private func bigCatalog(chapterCount: Int) -> BookCatalog {
        let chapters = (0..<chapterCount).map { chapter(Int64($0 + 1), "第 \($0 + 1) 章") }
        return catalog([volume(1, "正文", chapters)])
    }

    private let volumeH = CatalogListLayout.volumeRowHeight
    private let chapterH = CatalogListLayout.chapterRowHeight
    private let searchH = CatalogListLayout.searchRowHeight

    // MARK: - Flatten

    func testFlattensVolumesAndChaptersWithFixedHeights() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog)

        XCTAssertEqual(layout.rows.count, 7)
        XCTAssertEqual(layout.rows.map(\.height),
                       [volumeH, chapterH, chapterH, chapterH, volumeH, chapterH, chapterH])
        XCTAssertEqual(layout.totalHeight, 2 * volumeH + 5 * chapterH)
        XCTAssertFalse(layout.isEmpty)

        XCTAssertEqual(layout.rows[0].offset, 0)
        XCTAssertEqual(layout.rows[1].offset, volumeH)
        XCTAssertEqual(layout.rows[2].offset, volumeH + chapterH)
        XCTAssertEqual(layout.rows[4].offset, volumeH + 3 * chapterH)
        XCTAssertEqual(layout.rows[0].id, "v1")
        XCTAssertEqual(layout.rows[1].id, "c101")
        XCTAssertEqual(layout.rows[4].id, "v2")
    }

    func testVolumeHeaderCarriesTitleAndChapterCount() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog)

        guard case .volume(let volumeId, let title, let count, let collapsed) = layout.rows[0].kind else {
            return XCTFail("第一行应该是卷标题")
        }
        XCTAssertEqual(volumeId, 1)
        XCTAssertEqual(title, "第一卷")
        XCTAssertEqual(count, 3)
        XCTAssertFalse(collapsed)
    }

    func testEmptyVolumeNameFallsBackToBody() {
        let layout = CatalogListLayout(catalog: catalog([volume(9, "  ", [chapter(1, "第一章")])]))
        guard case .volume(_, let title, _, _) = layout.rows[0].kind else {
            return XCTFail("第一行应该是卷标题")
        }
        XCTAssertEqual(title, "正文")
    }

    func testCollapsedVolumeKeepsHeaderAndHidesChapters() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog, collapsedVolumes: [1])

        XCTAssertEqual(layout.rows.count, 4) // 第一卷标题 + 第二卷标题 + 2 章
        XCTAssertEqual(layout.totalHeight, 2 * volumeH + 2 * chapterH)
        guard case .volume(_, _, _, let collapsed) = layout.rows[0].kind else {
            return XCTFail("第一行应该是卷标题")
        }
        XCTAssertTrue(collapsed)
        XCTAssertNil(layout.index(ofChapterId: 101))
        XCTAssertEqual(layout.index(ofChapterId: 201), 2)
    }

    func testSearchRowsCarryVolumeNameAndUseTallerHeight() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog, query: "章")

        XCTAssertEqual(layout.keyword, "章")
        XCTAssertEqual(layout.rows.count, 5)
        XCTAssertEqual(layout.totalHeight, 5 * searchH)
        XCTAssertEqual(layout.rows.map(\.id), ["c101", "c102", "c103", "c201", "c202"])

        let names = layout.rows.map { row -> String? in
            guard case .chapter(_, let volumeName) = row.kind else { return nil }
            return volumeName
        }
        XCTAssertEqual(names, ["第一卷", "第一卷", "第一卷", "第二卷", "第二卷"])
    }

    func testSearchIgnoresCollapsedVolumes() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog,
                                       collapsedVolumes: [1, 2],
                                       query: "第")
        XCTAssertEqual(layout.rows.count, 5)
        XCTAssertEqual(layout.rows.allSatisfy { $0.height == searchH }, true)
    }

    func testBlankSearchFallsBackToVolumeBrowsing() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog, query: "   ")
        XCTAssertTrue(layout.keyword.isEmpty)
        XCTAssertEqual(layout.rows.count, 7)
    }

    func testEmptyCatalogProducesEmptyLayout() {
        let layout = CatalogListLayout(catalog: catalog([]))
        XCTAssertTrue(layout.isEmpty)
        XCTAssertEqual(layout.totalHeight, 0)
        XCTAssertEqual(layout.window(visibleTop: 0, visibleHeight: 400, buffer: 100), 0..<0)
        XCTAssertEqual(layout.spans(for: 0..<0).body, 0)
    }

    // MARK: - Window

    func testWindowCoversOnlyVisibleRangeWithoutBuffer() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 200))
        let visible: CGFloat = 360

        let range = layout.window(visibleTop: 0, visibleHeight: visible, buffer: 0)

        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertLessThan(range.upperBound, layout.rows.count)
        XCTAssertLessThan(layout.rows[range.upperBound - 1].offset, visible,
                          "窗口最后一行必须与可视区域相交")
        XCTAssertGreaterThanOrEqual(layout.rows[range.upperBound].offset, visible)
    }

    func testWindowAddsBufferAroundVisibleRange() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 200))
        let visible: CGFloat = 360

        let tight = layout.window(visibleTop: 2_000, visibleHeight: visible, buffer: 0)
        let buffered = layout.window(visibleTop: 2_000, visibleHeight: visible, buffer: visible)

        XCTAssertLessThan(buffered.lowerBound, tight.lowerBound)
        XCTAssertGreaterThan(buffered.upperBound, tight.upperBound)
        let previous = layout.rows[buffered.lowerBound - 1]
        XCTAssertLessThanOrEqual(previous.offset + previous.height, 2_000 - visible,
                                 "缓冲区起点之上的行不应被渲染")
    }

    func testWindowFollowsScrollOffset() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 200))
        let row = layout.rows[50]

        let range = layout.window(visibleTop: row.offset, visibleHeight: 360, buffer: 0)

        XCTAssertEqual(range.lowerBound, 50)
        XCTAssertTrue(range.contains(50))
    }

    func testWindowContainsPartiallyVisibleRows() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 200))
        // 从第 10 行中间开始看：第 10 行仍要被渲染。
        let top = layout.rows[10].offset + layout.rows[10].height / 2
        let range = layout.window(visibleTop: top, visibleHeight: 10, buffer: 0)

        XCTAssertEqual(range.lowerBound, 10)
        XCTAssertEqual(range.upperBound, 11)
    }

    func testWindowClampsAtBottom() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 200))

        let range = layout.window(visibleTop: layout.totalHeight * 2, visibleHeight: 360, buffer: 0)

        XCTAssertFalse(range.isEmpty, "越界滚动也要有行可渲染")
        XCTAssertEqual(range.upperBound, layout.rows.count)
        XCTAssertLessThanOrEqual(layout.totalHeight - layout.rows[range.lowerBound].offset, 360)
    }

    func testWindowSurvivesNegativeOverscroll() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 200))

        let range = layout.window(visibleTop: -500, visibleHeight: 360, buffer: 0)

        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertFalse(range.isEmpty)
    }

    func testLargeCatalogWindowStaysSmall() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 1_400))
        let visible: CGFloat = 480
        let buffer = visible

        for top in stride(from: CGFloat(0), through: layout.totalHeight, by: 7_000) {
            let range = layout.window(visibleTop: top, visibleHeight: visible, buffer: buffer)
            XCTAssertFalse(range.isEmpty)
            XCTAssertLessThan(range.count, 60, "窗口只应包含可视区 + 缓冲区的行")
            XCTAssertEqual(layout.totalHeight, volumeH + CGFloat(1_400) * chapterH)
        }
    }

    /// 模拟滚动：任意偏移下窗口都必须盖住整个可视范围，否则会露白。
    func testWindowAlwaysCoversViewportWhileScrolling() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 1_400))
        let visible: CGFloat = 487.5
        let buffer = visible

        var top: CGFloat = 0
        while top < layout.totalHeight {
            let range = layout.window(visibleTop: top, visibleHeight: visible, buffer: buffer)
            let firstVisible = layout.rows.firstIndex { $0.offset + $0.height > top } ?? layout.rows.count - 1
            let lastVisible = layout.rows.lastIndex { $0.offset < top + visible } ?? 0
            XCTAssertTrue(range.contains(firstVisible), "top=\(top) 首个可见行 \(firstVisible) 不在 \(range)")
            XCTAssertTrue(range.contains(lastVisible), "top=\(top) 末个可见行 \(lastVisible) 不在 \(range)")
            top += 37
        }
    }

    func testWindowCenteringRowBringsTargetIntoWindow() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 1_400))
        let visible: CGFloat = 480
        let target = 1_000

        let range = layout.window(centeringRow: target, visibleHeight: visible, buffer: visible * 0.75)

        XCTAssertTrue(range.contains(target))
        XCTAssertLessThan(range.count, 60)
        // 目标行大致在窗口中间。
        let center = layout.rows[target].offset + layout.rows[target].height / 2
        XCTAssertLessThan(abs(center - layout.rows[range.lowerBound].offset), visible * 2)
    }

    func testWindowCenteringOutOfRangeFallsBackToTop() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 10))
        let range = layout.window(centeringRow: 999, visibleHeight: 360, buffer: 0)
        XCTAssertEqual(range.lowerBound, 0)
    }

    // MARK: - Spans

    func testSpansFillTheWholeContentHeight() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 300))
        let visible: CGFloat = 480
        let buffer = visible * 0.75

        for top in stride(from: CGFloat(0), to: layout.totalHeight, by: 1_000) {
            let range = layout.window(visibleTop: top, visibleHeight: visible, buffer: buffer)
            let spans = layout.spans(for: range)

            XCTAssertEqual(spans.top + spans.body + spans.bottom, layout.totalHeight,
                           accuracy: 0.001,
                           "占位 + 窗口必须撑满总高度，滚动条才不会跳")
            XCTAssertEqual(spans.top, layout.rows[range.lowerBound].offset, accuracy: 0.001)
            let bodyEnd = range.upperBound < layout.rows.count
                ? layout.rows[range.upperBound].offset
                : layout.totalHeight
            XCTAssertEqual(spans.body, bodyEnd - layout.rows[range.lowerBound].offset, accuracy: 0.001)
        }
    }

    func testSpansAtWindowBoundaries() {
        let layout = CatalogListLayout(catalog: bigCatalog(chapterCount: 20))

        let whole = layout.spans(for: 0..<layout.rows.count)
        XCTAssertEqual(whole.top, 0)
        XCTAssertEqual(whole.body, layout.totalHeight)
        XCTAssertEqual(whole.bottom, 0)

        let empty = layout.spans(for: 0..<0)
        XCTAssertEqual(empty.top + empty.body + empty.bottom, layout.totalHeight, accuracy: 0.001)
    }

    // MARK: - Lookup / clamping

    func testIndexAndVolumeLookup() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog)

        XCTAssertEqual(layout.index(ofChapterId: 103), 3)
        XCTAssertEqual(layout.index(ofChapterId: 201), 5)
        XCTAssertNil(layout.index(ofChapterId: 999))

        XCTAssertEqual(layout.volumeId(containingChapterId: 102), 1)
        XCTAssertEqual(layout.volumeId(containingChapterId: 202), 2)
        XCTAssertNil(layout.volumeId(containingChapterId: 999))
    }

    func testVolumeLookupWorksForCollapsedVolume() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog, collapsedVolumes: [1])
        XCTAssertEqual(layout.volumeId(containingChapterId: 101), 1)
    }

    func testClampedRangeHandlesStaleWindow() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog)

        XCTAssertEqual(layout.clampedRange(0..<3), 0..<3)
        XCTAssertEqual(layout.clampedRange(5..<100), 5..<7)
        XCTAssertEqual(layout.clampedRange(100..<110), 7..<7)
        XCTAssertEqual(layout.clampedRange(-3..<2), 0..<2)
    }

    func testRowAtReturnsNilOutOfBounds() {
        let layout = CatalogListLayout(catalog: twoVolumeCatalog)
        XCTAssertEqual(layout.row(at: 2)?.id, "c102")
        XCTAssertNil(layout.row(at: 7))
        XCTAssertNil(layout.row(at: -1))
    }
}
