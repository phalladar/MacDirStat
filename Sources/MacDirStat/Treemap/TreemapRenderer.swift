import SwiftUI

/// Folders are frames with a title strip, files are blocks without one, so the two differ by
/// shape and not only by color. Colors are resolved once per draw, text once per item.
struct TreemapRenderer {
    let items: [TreemapItem]
    let zoomScale: CGFloat
    let panOffset: CGPoint
    let showLabels: Bool
    let sizeMetric: SizeMetric
    let colorMode: TreemapColorMode
    let contrast: ColorSchemeContrast

    /// Folder color mode: one per child of the shown folder, by size, wrapping after the last.
    private static let branchColors: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .indigo, .brown]
    /// Folders in type mode: graphite, so their own color can't pass for a category.
    private static let neutral = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.35, green: 0.35, blue: 0.37, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.72, blue: 0.75, alpha: 1)
    })
    private static let frameRadius: CGFloat = 6, blockRadius: CGFloat = 4
    private static let tabHeight: CGFloat = 3, barHeight: CGFloat = 4

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let viewport = CGRect(origin: .zero, size: size)
        let environment = context.environment
        let dark = environment.colorScheme == .dark
        let tones: [Tone], categoryTones: [Tone]
        switch colorMode {
        case .type:
            tones = [Tone(Self.neutral, dark: dark, in: environment)]
            categoryTones = FileCategory.allCases.map { Tone($0.color, dark: dark, in: environment) }
        case .folder:
            tones = Self.branchColors.map { Tone($0, dark: dark, in: environment) }
            categoryTones = []
        }
        let categoryColors = colorMode == .type ? FileCategory.allCases.map { $0.color.resolve(in: environment) } : []
        // Increase Contrast: every frame and block outlined in the separator color, fully opaque.
        var outlines: Color?
        if contrast == .increased {
            var separator = Color(nsColor: .separatorColor).resolve(in: environment)
            separator.opacity = 1
            outlines = Color(separator)
        }
        let frameShade = Color.black.opacity(dark ? 0.16 : 0.05)
        let titleColor: Color = dark ? .white : .black
        let stripHeight = TreemapMetrics.titleHeight * zoomScale

        var stripes = Path()
        var titles: [(GraphicsContext.ResolvedText, CGRect)] = []
        var labels: [(GraphicsContext.ResolvedText, CGRect)] = []

        for item in items {
            let rect = CGRect(x: panOffset.x + item.rect.x * zoomScale, y: panOffset.y + item.rect.y * zoomScale,
                              width: item.rect.width * zoomScale, height: item.rect.height * zoomScale)
            guard rect.intersects(viewport), rect.width >= 0.5, rect.height >= 0.5 else { continue }
            let tone = colorMode == .folder ? tones[item.branch % tones.count]
                : item.kind == .file ? categoryTones[item.node.category.index] : tones[0]

            switch item.kind {
            case .file:
                let block = Path(roundedRect: rect, cornerRadius: Self.radius(Self.blockRadius, rect))
                context.fill(block, with: tone.tile(rect))
                if let outlines { context.stroke(block, with: .color(outlines), lineWidth: 1) }
                if showLabels, let label = tileLabel(item.node.name, item.node.size(for: sizeMetric), in: rect, context) {
                    labels.append(label)
                }

            case .smallerItems(let count, let total):
                let block = Path(roundedRect: rect, cornerRadius: Self.radius(Self.blockRadius, rect))
                context.fill(block, with: tone.body(rect))
                stripes.addPath(block)
                if let outlines { context.stroke(block, with: .color(outlines), lineWidth: 1) }
                // Says what it gathered, never the folder's name; on stripes, in the title color.
                if showLabels && rect.width > 56 && rect.height > 20 {
                    let text = Text(verbatim: "\(count) smaller items · \(ByteFormatter.string(from: total))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(titleColor)
                    titles.append((context.resolve(text), rect.insetBy(dx: 6, dy: 4)))
                }

            case .closedFolder where !item.hasTitleStrip:
                // No room for a title: a block with a light tab on top marks it as a folder.
                let radius = Self.radius(Self.blockRadius, rect)
                let block = Path(roundedRect: rect, cornerRadius: radius)
                context.fill(block, with: tone.body(rect))
                let tab = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(Self.tabHeight * zoomScale, rect.height / 3))
                context.fill(Path(roundedRect: tab, cornerRadii: .init(topLeading: radius, topTrailing: radius)),
                             with: .color(tone.tab))
                if !dark {
                    // A light body needs a line under the tab for the tab to read.
                    context.fill(Path(CGRect(x: tab.minX, y: tab.maxY, width: tab.width, height: 1)), with: .color(tone.edge))
                }
                if let outlines { context.stroke(block, with: .color(outlines), lineWidth: 1) }
                if rect.height > 14 {
                    makeupBar(item.node, in: CGRect(x: rect.minX + 4, y: rect.maxY - Self.barHeight - 4,
                                                    width: rect.width - 8, height: Self.barHeight),
                              colors: categoryColors, context)
                }

            case .openFolder, .closedFolder:
                let open = item.kind == .openFolder
                let radius = Self.radius(Self.frameRadius, rect)
                let frame = Path(roundedRect: rect, cornerRadius: radius)
                context.fill(frame, with: open ? .color(frameShade) : tone.body(rect))
                let strip = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(stripHeight, rect.height))
                context.fill(Path(roundedRect: strip, cornerRadii: .init(topLeading: radius, topTrailing: radius)),
                             with: .color(tone.strip))
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, radius - 0.5)),
                               with: .color(outlines ?? tone.edge), lineWidth: 1)
                if !open && rect.height > stripHeight + 14 {
                    makeupBar(item.node, in: CGRect(x: rect.minX + 7, y: rect.minY + stripHeight + 5,
                                                    width: min(rect.width - 14, 160), height: Self.barHeight),
                              colors: categoryColors, context)
                }
                if showLabels && rect.width >= 40 {
                    let title = Text(verbatim: "\(open ? "▾" : "▸") \(item.node.name) ").fontWeight(.semibold)
                    let detail = Text(verbatim: "· \(ByteFormatter.string(from: item.node.size(for: sizeMetric)))")
                        .foregroundStyle(titleColor.opacity(0.6))
                    let text = (title + detail).font(.system(size: 11)).foregroundStyle(titleColor)
                    titles.append((context.resolve(text), CGRect(x: rect.minX + 6, y: rect.minY + (stripHeight - 14) / 2,
                                                                 width: rect.width - 12, height: 14)))
                }
            }
        }

        if !stripes.isEmpty { drawStripes(clippedTo: stripes, dark: dark, context) }
        for (text, rect) in titles { context.draw(text, in: rect) }
        if !labels.isEmpty {
            // One shadowed layer for every block label instead of a shadow per label.
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 1, y: 0.5))
                for (text, rect) in labels { layer.draw(text, in: rect) }
            }
        }
    }

    /// Name over size, in white with a light shadow, when the block has room for it.
    private func tileLabel(_ name: String, _ size: Int64, in rect: CGRect,
                           _ context: GraphicsContext) -> (GraphicsContext.ResolvedText, CGRect)? {
        guard rect.width > 56 && rect.height > 20 else { return nil }
        let box = CGRect(x: rect.minX + 6, y: rect.minY + 4, width: rect.width - 12, height: rect.height - 6)
        let text = rect.height > 38
            ? Text(verbatim: name + "\n").fontWeight(.semibold)
                + Text(verbatim: ByteFormatter.string(from: size)).foregroundStyle(.white.opacity(0.75))
            : Text(verbatim: name).fontWeight(.semibold)
        return (context.resolve(text.font(.system(size: 11)).foregroundStyle(.white)), box)
    }

    /// The folder's real split by category, like the sidebar's SizeSparkline. Type mode only.
    private func makeupBar(_ folder: FileNode, in bar: CGRect, colors: [Color.Resolved], _ context: GraphicsContext) {
        guard colorMode == .type, bar.width >= 24 else { return }
        let segments = folder.categoryBreakdown(metric: sizeMetric)
        let total = segments.reduce(0) { $0 + $1.size }
        guard total > 0 else { return }
        var clipped = context
        clipped.clip(to: Path(roundedRect: bar, cornerRadius: bar.height / 2))
        var x = bar.minX
        for segment in segments {
            let width = bar.width * CGFloat(segment.size) / CGFloat(total)
            clipped.fill(Path(CGRect(x: x, y: bar.minY, width: width, height: bar.height)),
                         with: .color(Color(colors[segment.category.index])))
            x += width
        }
    }

    /// Diagonal stripes over every smallerItems block at once: one clip, one stroke.
    private func drawStripes(clippedTo blocks: Path, dark: Bool, _ context: GraphicsContext) {
        let bounds = blocks.boundingRect
        var lines = Path()
        var x = bounds.minX - bounds.height
        while x < bounds.maxX {
            lines.move(to: CGPoint(x: x, y: bounds.maxY))
            lines.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
            x += 8
        }
        var clipped = context
        clipped.clip(to: blocks)
        clipped.stroke(lines, with: .color(dark ? .black.opacity(0.22) : .white.opacity(0.4)), lineWidth: 3)
    }

    /// The corner radius of `item` drawn at `rect`, for overlays that trace its outline.
    static func cornerRadius(of item: TreemapItem, in rect: CGRect) -> CGFloat {
        radius(item.hasTitleStrip ? frameRadius : blockRadius, rect)
    }

    /// Never rounder than a quarter of the shorter side, so small blocks keep their shape.
    private static func radius(_ base: CGFloat, _ rect: CGRect) -> CGFloat {
        min(base, min(rect.width, rect.height) / 4)
    }
}

/// The shades drawn from one base color, resolved once per draw.
private struct Tone {
    let tileGradient: Gradient, bodyGradient: Gradient
    let strip: Color, edge: Color, tab: Color

    init(_ color: Color, dark: Bool, in environment: EnvironmentValues) {
        let base = color.resolve(in: environment)
        func scaled(_ f: Float) -> Color {
            Color(Color.Resolved(red: min(1, base.red * f), green: min(1, base.green * f), blue: min(1, base.blue * f)))
        }
        func lighter(_ t: Float) -> Color {
            Color(Color.Resolved(red: base.red + (1 - base.red) * t, green: base.green + (1 - base.green) * t,
                                 blue: base.blue + (1 - base.blue) * t))
        }
        tileGradient = Gradient(colors: [lighter(0.12), dark ? scaled(0.92) : Color(base)])
        bodyGradient = Gradient(colors: dark ? [scaled(0.8), scaled(0.66)] : [lighter(0.3), lighter(0.2)])
        strip = dark ? scaled(0.5) : lighter(0.5)
        edge = dark ? scaled(0.6) : scaled(0.85)
        tab = lighter(dark ? 0.4 : 0.9)
    }

    /// A file: the top a little lighter than the bottom.
    func tile(_ rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(tileGradient,
                        startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.minX, y: rect.maxY))
    }

    /// A closed folder or a smallerItems block: quieter than a file of the same tone.
    func body(_ rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(bodyGradient,
                        startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.minX, y: rect.maxY))
    }
}
