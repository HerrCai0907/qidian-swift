import SwiftUI
import AppKit
import CoreText
import QidianKit

// MARK: - Paginated reader

/// 分页阅读视图：左右各一页，点击左侧上一页，点击中间/右侧下一页。
/// 当前章最后一页再点下一页时，自动进入下一章。
struct PagedReaderView: View {
    let chapter: LoadedChapter
    @Environment(ReaderStore.self) private var store

    @State private var pagination: ChapterPagination?
    @State private var spreadIndex = 0
    @State private var anchor = 0
    @State private var lastChapterId: Int64 = 0
    @State private var lastFingerprint = 0
    @State private var landing: Landing = .start
    @FocusState private var isFocused: Bool

    private enum Landing {
        case start
        case end
    }

    private enum Layout {
        static let horizontalPadding: CGFloat = 24
        static let verticalPadding: CGFloat = 14
        static let gutter: CGFloat = 22
        static let pageInset: CGFloat = 22
        static let footerHeight: CGFloat = 20
        static let footerSpacing: CGFloat = 10
        static let cornerRadius: CGFloat = 8
    }

    private struct Metrics {
        let cardSize: CGSize
        let textSize: CGSize
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = metrics(for: proxy.size)
            let key = paginationKey(textSize: metrics.textSize)

            VStack(spacing: Layout.footerSpacing) {
                HStack(spacing: Layout.gutter) {
                    pageCard(index: spreadIndex * 2,
                             textSize: metrics.textSize,
                             cardSize: metrics.cardSize)
                    pageCard(index: spreadIndex * 2 + 1,
                             textSize: metrics.textSize,
                             cardSize: metrics.cardSize)
                }
                .overlay {
                    MousePageTurnOverlay(
                        onLeftClick: { fraction in
                            isFocused = true
                            if fraction < 1.0 / 3.0 {
                                goPrevious()
                            } else {
                                goNext()
                            }
                        },
                        onRightClick: {
                            isFocused = true
                            goPrevious()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                footer
            }
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.vertical, Layout.verticalPadding)
            .onChange(of: key, initial: true) { _, _ in
                repaginate(textSize: metrics.textSize)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) {
                goPrevious()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                goNext()
                return .handled
            }
            .onAppear { isFocused = true }
            .onChange(of: chapter.chapterId) { _, _ in
                isFocused = true
            }
        }
    }

    // MARK: - Page layout

    private func metrics(for size: CGSize) -> Metrics {
        let availableWidth = max(1, size.width - Layout.horizontalPadding * 2)
        let cardWidth = max(120, (availableWidth - Layout.gutter) / 2)
        let availableHeight = max(1, size.height
            - Layout.verticalPadding * 2
            - Layout.footerHeight
            - Layout.footerSpacing)
        let cardHeight = max(120, availableHeight)
        let textSize = CGSize(
            width: max(60, cardWidth - Layout.pageInset * 2),
            height: max(60, cardHeight - Layout.pageInset * 2)
        )
        return Metrics(cardSize: CGSize(width: cardWidth, height: cardHeight),
                       textSize: textSize)
    }

    @ViewBuilder
    private func pageCard(index: Int, textSize: CGSize, cardSize: CGSize) -> some View {
        let range = pagination.flatMap { index < $0.ranges.count ? $0.ranges[index] : nil }

        ZStack {
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .fill(store.theme.pageBackground)

            if let pagination, let range {
                CoreTextPageView(attributed: pagination.attributed, range: range)
                    .frame(width: textSize.width, height: textSize.height)
                    .padding(Layout.pageInset)
            } else if pagination == nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
        .shadow(color: store.theme.pageShadow, radius: 5, x: 0, y: 2)
        .overlay {
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .strokeBorder(store.theme.pageBorder, lineWidth: 0.5)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(chapter.bookName.isEmpty ? chapter.title : chapter.bookName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(footerHint)
                .lineLimit(1)
                .foregroundStyle(store.theme.tertiaryForeground)

            Spacer(minLength: 8)

            Text(pageIndicator)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(store.theme.secondaryForeground)
        .frame(height: Layout.footerHeight)
    }

    private var footerHint: String {
        guard let pagination, !pagination.ranges.isEmpty else { return "" }
        let lastSpread = max(0, (pagination.ranges.count - 1) / 2)
        guard spreadIndex >= lastSpread else {
            return "←/右键上一页 · →/点击下一页"
        }
        if let nextName = chapter.nextName, !nextName.isEmpty {
            return "再点下一页或按 →：\(nextName)"
        }
        if let nextId = chapter.nextId, nextId > 0 {
            return "再点下一页或按 → 进入下一章"
        }
        return "本章完"
    }

    private var pageIndicator: String {
        guard let pagination, !pagination.ranges.isEmpty else { return "— / —" }
        let total = pagination.ranges.count
        let first = min(spreadIndex * 2 + 1, total)
        let second = min(spreadIndex * 2 + 2, total)
        return first == second
            ? "第 \(first) / \(total) 页"
            : "第 \(first)-\(second) / \(total) 页"
    }

    // MARK: - Paging

    private func goNext() {
        guard !isLoading, let pagination, !pagination.ranges.isEmpty else { return }
        let lastSpread = max(0, (pagination.ranges.count - 1) / 2)

        if spreadIndex < lastSpread {
            spreadIndex += 1
            anchor = pagination.ranges[spreadIndex * 2].location
            recordProgress()
            return
        }

        guard let nextId = chapter.nextId, nextId > 0 else { return }
        landing = .start
        Task { await store.openAdjacent(nextId) }
    }

    private func goPrevious() {
        guard !isLoading, let pagination, !pagination.ranges.isEmpty else { return }

        if spreadIndex > 0 {
            spreadIndex -= 1
            anchor = pagination.ranges[spreadIndex * 2].location
            recordProgress()
            return
        }

        guard let prevId = chapter.prevId, prevId > 0 else { return }
        landing = .end
        Task {
            let ok = await store.openAdjacent(prevId)
            if !ok { landing = .start }
        }
    }

    private var isLoading: Bool {
        if case .loading = store.phase { return true }
        return false
    }

    // MARK: - Pagination

    private var contentFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(chapter.title)
        hasher.combine(chapter.bookName)
        hasher.combine(chapter.authorName)
        hasher.combine(chapter.volumeName)
        hasher.combine(chapter.wordsCount)
        hasher.combine(chapter.isPreview)
        hasher.combine(chapter.authorSay)
        hasher.combine(chapter.paragraphs)
        return hasher.finalize()
    }

    private func paginationKey(textSize: CGSize) -> PaginationKey {
        PaginationKey(chapterId: chapter.chapterId,
                      contentFingerprint: contentFingerprint,
                      restoreGeneration: store.restoreGeneration,
                      fontSize: store.fontSize,
                      lineSpacing: store.lineSpacing,
                      theme: store.theme.rawValue,
                      width: textSize.width,
                      height: textSize.height)
    }

    private func repaginate(textSize: CGSize) {
        guard textSize.width > 1, textSize.height > 1 else { return }

        let fingerprint = contentFingerprint
        let contentChanged = chapter.chapterId != lastChapterId || fingerprint != lastFingerprint
        let previousAnchor = anchor
        let resumeAnchor = store.consumeRestoreAnchor(bookId: chapter.bookId,
                                                      chapterId: chapter.chapterId)

        let result = ChapterPaginator.build(chapter: chapter,
                                            fontSize: store.fontSize,
                                            lineSpacing: store.lineSpacing,
                                            theme: store.theme,
                                            pageSize: textSize)
        pagination = result
        let ranges = result.ranges

        if let resumeAnchor, !ranges.isEmpty {
            let maxOffset = max(0, result.attributed.length - 1)
            let target = max(0, min(maxOffset, result.bodyStart + resumeAnchor))
            let index = ranges.firstIndex { target < $0.location + $0.length } ?? 0
            spreadIndex = index / 2
        } else if contentChanged {
            if landing == .end {
                spreadIndex = max(0, (ranges.count - 1) / 2)
            } else {
                spreadIndex = 0
            }
        } else {
            let index = ranges.firstIndex { previousAnchor < $0.location + $0.length }
                ?? max(0, ranges.count - 1)
            spreadIndex = index / 2
        }
        if contentChanged || resumeAnchor != nil {
            landing = .start
        }

        if ranges.isEmpty {
            anchor = 0
        } else {
            anchor = ranges[min(spreadIndex * 2, ranges.count - 1)].location
        }
        lastChapterId = chapter.chapterId
        lastFingerprint = fingerprint
        // 只在换章/内容变化/主动跳到历史位置时记录；窗口缩放、主题切换不重复写盘。
        if contentChanged || resumeAnchor != nil {
            recordProgress()
        }
    }

    /// 当前左页起点相对正文起点的偏移，写入历史记录。
    private func recordProgress() {
        guard let pagination, !pagination.ranges.isEmpty else { return }
        let index = min(spreadIndex * 2, pagination.ranges.count - 1)
        let pageStart = pagination.ranges[index].location
        store.recordProgress(chapter: chapter, anchor: pageStart - pagination.bodyStart)
    }
}

// MARK: - Mouse page turning

/// 用 AppKit 原生鼠标事件处理左右键，避免 SwiftUI 的透明手势区接不到右键。
private struct MousePageTurnOverlay: NSViewRepresentable {
    let onLeftClick: (CGFloat) -> Void
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> MousePageTurnNSView {
        let view = MousePageTurnNSView()
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: MousePageTurnNSView, context: Context) {
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
    }
}

private final class MousePageTurnNSView: NSView {
    var onLeftClick: ((CGFloat) -> Void)?
    var onRightClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = bounds.width > 0
            ? min(max(point.x / bounds.width, 0), 1)
            : 0.5
        onLeftClick?(fraction)
    }

    override func rightMouseUp(with event: NSEvent) {
        onRightClick?()
    }
}

// MARK: - Pagination key / result

private struct PaginationKey: Hashable {
    let chapterId: Int64
    let contentFingerprint: Int
    let restoreGeneration: Int
    let fontSize: Double
    let lineSpacing: Double
    let theme: String
    let width: CGFloat
    let height: CGFloat
}

private struct ChapterPagination {
    let attributed: NSAttributedString
    let ranges: [NSRange]
    /// 正文第一段在 attributed 中的起点，用于把历史进度锚点换算成排版位置。
    let bodyStart: Int
}

// MARK: - CoreText paginator

private enum ChapterPaginator {
    static func build(chapter: LoadedChapter,
                      fontSize: Double,
                      lineSpacing: Double,
                      theme: ReaderTheme,
                      pageSize: CGSize) -> ChapterPagination {
        let (attributed, bodyStart) = makeAttributedString(chapter: chapter,
                                                           fontSize: fontSize,
                                                           lineSpacing: lineSpacing,
                                                           theme: theme)
        return ChapterPagination(attributed: attributed,
                                 ranges: paginate(attributed, pageSize: pageSize),
                                 bodyStart: bodyStart)
    }

    private static func makeAttributedString(chapter: LoadedChapter,
                                             fontSize: Double,
                                             lineSpacing: Double,
                                             theme: ReaderTheme) -> (NSAttributedString, Int) {
        let bodySize = max(10, CGFloat(fontSize))
        let extraLineSpacing = max(0, CGFloat(lineSpacing))
        let foreground = NSColor(theme.foreground)
        let secondary = NSColor(theme.foreground.opacity(0.55))
        let accent = NSColor.systemOrange

        let titleFont = serifFont(size: bodySize + 8, weight: .semibold)
        let metaFont = serifFont(size: max(10, bodySize - 4), weight: .regular)
        let bodyFont = serifFont(size: bodySize, weight: .regular)
        let authorFont = serifFont(size: max(10, bodySize - 2), weight: .regular)

        let titleStyle = paragraphStyle(lineSpacing: 2, paragraphSpacing: 8)
        let metaStyle = paragraphStyle(lineSpacing: 2, paragraphSpacing: 12)
        let bodyStyle = paragraphStyle(lineSpacing: extraLineSpacing, paragraphSpacing: 8)
        bodyStyle.alignment = .justified
        let authorStyle = paragraphStyle(lineSpacing: max(2, extraLineSpacing * 0.7),
                                         paragraphSpacing: 6)

        let output = NSMutableAttributedString()
        output.append(NSAttributedString(
            string: (chapter.title.isEmpty ? "未命名章节" : chapter.title) + "\n",
            attributes: [.font: titleFont, .foregroundColor: foreground, .paragraphStyle: titleStyle]
        ))

        var meta: [String] = []
        if !chapter.bookName.isEmpty { meta.append("《\(chapter.bookName)》") }
        if !chapter.authorName.isEmpty { meta.append(chapter.authorName) }
        if let volume = chapter.volumeName, !volume.isEmpty { meta.append(volume) }
        meta.append("\(chapter.wordsCount) 字")
        if chapter.isFromCache { meta.append("本地缓存") }
        if chapter.isPreview { meta.append("试读") }
        output.append(NSAttributedString(
            string: meta.joined(separator: " · ") + "\n",
            attributes: [.font: metaFont, .foregroundColor: secondary, .paragraphStyle: metaStyle]
        ))

        if chapter.isPreview {
            output.append(NSAttributedString(
                string: "当前仅能读到试读片段，订阅本章后可读全文。\n",
                attributes: [.font: metaFont, .foregroundColor: accent, .paragraphStyle: metaStyle]
            ))
        }

        let bodyStart = output.length

        for paragraph in chapter.paragraphs {
            output.append(NSAttributedString(
                string: "　　\(paragraph)\n",
                attributes: [.font: bodyFont, .foregroundColor: foreground, .paragraphStyle: bodyStyle]
            ))
        }

        if let say = chapter.authorSay, !say.isEmpty {
            output.append(NSAttributedString(
                string: "\n作者说\n",
                attributes: [.font: metaFont, .foregroundColor: secondary, .paragraphStyle: metaStyle]
            ))
            output.append(NSAttributedString(
                string: "　　\(say)\n",
                attributes: [.font: authorFont, .foregroundColor: secondary, .paragraphStyle: authorStyle]
            ))
        }

        return (output, bodyStart)
    }

    private static func paginate(_ attributed: NSAttributedString,
                                 pageSize: CGSize) -> [NSRange] {
        let total = attributed.length
        guard total > 0 else { return [NSRange(location: 0, length: 0)] }
        guard pageSize.width > 1, pageSize.height > 1 else {
            return [NSRange(location: 0, length: total)]
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
        let string = attributed.string as NSString

        var ranges: [NSRange] = []
        var location = 0
        while location < total {
            let frame = CTFramesetterCreateFrame(framesetter,
                                                 CFRange(location: location, length: 0),
                                                 path,
                                                 nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            var end = max(location + 1, visible.location + visible.length)
            end = min(total, end)
            end = graphemeSafeEnd(end, in: string, lowerBound: location)
            ranges.append(NSRange(location: location, length: end - location))
            location = end
        }

        return ranges.isEmpty ? [NSRange(location: 0, length: total)] : ranges
    }

    private static func graphemeSafeEnd(_ proposed: Int,
                                        in string: NSString,
                                        lowerBound: Int) -> Int {
        let total = string.length
        var end = min(max(proposed, lowerBound + 1), total)
        guard end > 0, end < total else { return end }
        let sequence = string.rangeOfComposedCharacterSequence(at: end)
        if sequence.location < end, sequence.location > lowerBound {
            end = sequence.location
        }
        return end
    }

    private static func paragraphStyle(lineSpacing: CGFloat,
                                       paragraphSpacing: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return font
    }
}

// MARK: - CoreText page rendering

private struct CoreTextPageView: NSViewRepresentable {
    let attributed: NSAttributedString
    let range: NSRange

    func makeNSView(context: Context) -> CoreTextPageNSView {
        let view = CoreTextPageNSView()
        view.attributed = attributed
        view.range = range
        return view
    }

    func updateNSView(_ view: CoreTextPageNSView, context: Context) {
        view.attributed = attributed
        view.range = range
        view.needsDisplay = true
    }
}

private final class CoreTextPageNSView: NSView {
    var attributed: NSAttributedString?
    var range = NSRange(location: 0, length: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// 点击翻页由 SwiftUI 的透明区域处理，文字视图本身不拦截鼠标事件。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let attributed, range.length > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.textMatrix = .identity

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: bounds.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter,
                                             CFRange(location: range.location, length: 0),
                                             path,
                                             nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
