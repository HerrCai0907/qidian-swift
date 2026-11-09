import CoreGraphics
import Foundation
import QidianKit

/// 章节目录 sheet 的扁平化布局模型。
///
/// 把「卷标题 + 章节」展开成一串**固定行高**的行，并记录每行在滚动内容里的偏移。
/// 因为行高固定，滚动内容的总高度、以及任意可视范围对应的行区间都能直接算出来，
/// 不需要先把 1000+ 章全部排版；界面只实例化可视范围 + 缓冲区的几十行
/// （见 `window(visibleTop:visibleHeight:buffer:)`）。
///
/// 纯几何计算，不依赖 SwiftUI，方便单测。
struct CatalogListLayout: Equatable {
    enum RowKind: Equatable {
        case volume(volumeId: Int64, title: String, chapterCount: Int, isCollapsed: Bool)
        case chapter(CatalogChapter, volumeName: String?)
    }

    struct Row: Identifiable, Equatable {
        /// 稳定 id：卷用 `v<volumeId>`，章节用 `c<chapterId>`，可直接给 `ScrollViewProxy.scrollTo`。
        let id: String
        let kind: RowKind
        let height: CGFloat
        let offset: CGFloat
    }

    // MARK: - Row heights

    static let volumeRowHeight: CGFloat = 35
    static let chapterRowHeight: CGFloat = 36
    /// 搜索结果多显示一行所属卷名，所以更高。
    static let searchRowHeight: CGFloat = 50

    // MARK: - Content

    let rows: [Row]
    /// 全部行的总高度；只渲染部分行时用它撑住滚动内容，滚动条长度才不会跳。
    let totalHeight: CGFloat
    /// 搜索关键词（空关键词表示按卷浏览）。
    let keyword: String
    /// 章节 → 所属卷，建布局时顺手建好；折叠卷里没渲染的章节也能查到。
    private let chapterVolumeIds: [Int64: Int64]

    var isEmpty: Bool { rows.isEmpty }

    // MARK: - Build

    init(catalog: BookCatalog,
         collapsedVolumes: Set<Int64> = [],
         query: String = "",
         volumeRowHeight: CGFloat = CatalogListLayout.volumeRowHeight,
         chapterRowHeight: CGFloat = CatalogListLayout.chapterRowHeight,
         searchRowHeight: CGFloat = CatalogListLayout.searchRowHeight) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyword = keyword

        var rows: [Row] = []
        rows.reserveCapacity(catalog.chapterCount + catalog.volumes.count)
        var offset: CGFloat = 0
        var chapterVolumeIds: [Int64: Int64] = [:]
        chapterVolumeIds.reserveCapacity(catalog.chapterCount)

        func append(id: String, kind: RowKind, height: CGFloat) {
            rows.append(Row(id: id, kind: kind, height: height, offset: offset))
            offset += height
        }

        if keyword.isEmpty {
            for volume in catalog.volumes {
                let collapsed = collapsedVolumes.contains(volume.id)
                append(id: Self.volumeRowId(volume.volumeId),
                       kind: .volume(volumeId: volume.volumeId,
                                     title: volume.displayName,
                                     chapterCount: volume.chapterCount,
                                     isCollapsed: collapsed),
                       height: volumeRowHeight)
                for chapter in volume.chapters {
                    chapterVolumeIds[chapter.chapterId] = volume.volumeId
                }
                guard !collapsed else { continue }
                for chapter in volume.chapters {
                    append(id: Self.chapterRowId(chapter.chapterId),
                           kind: .chapter(chapter, volumeName: nil),
                           height: chapterRowHeight)
                }
            }
        } else {
            // 直接按卷遍历并用当前卷名，避免逐行回目录里查所属卷（O(n²)）。
            for volume in catalog.volumes {
                let name = volume.displayName
                for chapter in volume.chapters {
                    chapterVolumeIds[chapter.chapterId] = volume.volumeId
                    guard chapter.displayTitle.localizedCaseInsensitiveContains(keyword) else { continue }
                    append(id: Self.chapterRowId(chapter.chapterId),
                           kind: .chapter(chapter, volumeName: name),
                           height: searchRowHeight)
                }
            }
        }

        self.rows = rows
        self.totalHeight = offset
        self.chapterVolumeIds = chapterVolumeIds
    }

    /// 空布局（还没加载目录时）。
    init() {
        rows = []
        totalHeight = 0
        keyword = ""
        chapterVolumeIds = [:]
    }

    static func volumeRowId(_ volumeId: Int64) -> String { "v\(volumeId)" }
    static func chapterRowId(_ chapterId: Int64) -> String { "c\(chapterId)" }

    // MARK: - Lookup

    func row(at index: Int) -> Row? {
        rows.indices.contains(index) ? rows[index] : nil
    }

    /// 章节在行列表里的下标；折叠卷里的章节不算。
    func index(ofChapterId chapterId: Int64) -> Int? {
        rows.firstIndex { row in
            if case .chapter(let chapter, _) = row.kind {
                return chapter.chapterId == chapterId
            }
            return false
        }
    }

    func clampedRange(_ range: Range<Int>) -> Range<Int> {
        let lower = min(max(range.lowerBound, 0), rows.count)
        let upper = min(max(range.upperBound, lower), rows.count)
        return lower..<upper
    }

    /// 章节所属的卷 id，用于跳章前自动展开折叠的卷。
    ///
    /// 折叠卷里的章节不在行列表里，所以查的是建布局时缓存的「章节 → 卷」映射。
    func volumeId(containingChapterId chapterId: Int64) -> Int64? {
        chapterVolumeIds[chapterId]
    }

    // MARK: - Windowing

    /// 由可视区域推出要渲染的行区间：可视范围上下各多留 `buffer` 点。
    ///
    /// 返回值用下标区间表示，未渲染的行由调用方用空白占位撑住高度。
    func window(visibleTop: CGFloat, visibleHeight: CGFloat, buffer: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let height = max(visibleHeight, 1)
        let padding = max(buffer, 0)
        // 回弹滚动时 visibleTop 可能越界，夹回有效范围，保证窗口里总有行可渲染。
        let top = min(max(visibleTop, 0), max(0, totalHeight - height))
        let start = top - padding
        let end = top + height + padding

        let lower = firstIndex(whereRowEndIsAfter: start)
        let upper = firstIndex(whereRowStartIsAtOrAfter: end)
        return clampedRange(lower..<max(lower, upper))
    }

    /// 以某一行为中心取窗口，用于「跳到当前章」时先让目标行进入渲染范围。
    func window(centeringRow index: Int, visibleHeight: CGFloat, buffer: CGFloat) -> Range<Int> {
        guard rows.indices.contains(index) else { return window(visibleTop: 0, visibleHeight: visibleHeight, buffer: buffer) }
        let height = max(visibleHeight, 1)
        return window(visibleTop: rows[index].offset - height / 2,
                      visibleHeight: height,
                      buffer: buffer)
    }

    /// 窗口上下的占位高度与窗口自身高度；三段加起来恰好是 `totalHeight`。
    func spans(for range: Range<Int>) -> (top: CGFloat, body: CGFloat, bottom: CGFloat) {
        let clamped = clampedRange(range)
        guard let first = rows[safe: clamped.lowerBound] else {
            return (0, 0, totalHeight)
        }
        let top = first.offset
        let bodyEnd: CGFloat
        if let afterWindow = rows[safe: clamped.upperBound] {
            bodyEnd = afterWindow.offset
        } else {
            bodyEnd = totalHeight
        }
        let body = max(0, bodyEnd - top)
        return (top, body, max(0, totalHeight - top - body))
    }

    // MARK: - Private

    private func firstIndex(whereRowEndIsAfter y: CGFloat) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].offset + rows[mid].height <= y {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func firstIndex(whereRowStartIsAtOrAfter y: CGFloat) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].offset < y {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
