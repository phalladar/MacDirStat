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
    /// Each item's opacity while a transition runs; nil, the idle case, draws everything opaque.
    var opacities: [Double]? = nil

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
        let scale = environment.displayScale
        // Increase Contrast: every frame and block outlined in the separator color, fully opaque.
        var outlines: Color?
        if contrast == .increased {
            var separator = Color(nsColor: .separatorColor).resolve(in: environment)
            separator.opacity = 1
            outlines = Color(separator)
        }
        let frameShade = Color.black.opacity(dark ? 0.16 : 0.05)
        let titleColor: Color = dark ? .white : .black
        let stripHeight = Self.snap(TreemapMetrics.titleHeight * zoomScale, scale)

        let fading = opacities != nil
        var stripes = Path()
        var titles: [(GraphicsContext.ResolvedText, CGRect)] = []
        var labels: [(GraphicsContext.ResolvedText, CGRect)] = []

        for (index, item) in items.enumerated() {
            let rect = Self.screenRect(of: item, zoomScale: zoomScale, panOffset: panOffset, scale: scale)
            guard rect.intersects(viewport), rect.width >= 0.5, rect.height >= 0.5 else { continue }
            let opacity = opacities?[index] ?? 1
            if fading { context.opacity = opacity }
            // Text is most of a frame's cost, so an item fading in or out goes without.
            let labeled = showLabels && opacity == 1
            let tone = colorMode == .folder ? tones[item.branch % tones.count]
                : item.kind == .file ? categoryTones[item.node.category.index] : tones[0]
            // Each item is one fill of one shape, its bands hard stops of one gradient, so its edge
            // is antialiased once. Separation comes from the gap; a 1 pt sheen lights the top edge.
            let shape = Self.outline(of: item, in: rect)

            switch item.kind {
            case .file:
                context.fill(shape, with: Self.bands(rect, (tone.tileSheen, 1), body: tone.tileTop, tone.tileBottom))
                if labeled, let label = tileLabel(item.node.name, item.node.size(for: sizeMetric), in: rect, context) {
                    labels.append(label)
                }

            case .smallerItems(let count, let total):
                context.fill(shape, with: Self.bands(rect, (tone.bodySheen, 1), body: tone.bodyTop, tone.bodyBottom))
                // The stripes go on in one pass at full opacity, so a fading block goes without.
                if opacity == 1 { stripes.addPath(shape) }
                // Says what it gathered, never the folder's name; on stripes, in the title color.
                if labeled && rect.width > 56 && rect.height > 20 {
                    let text = Text(verbatim: "\(count) smaller items · \(ByteFormatter.string(from: total))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(titleColor)
                    titles.append((context.resolve(text), rect.insetBy(dx: 6, dy: 4)))
                }

            case .closedFolder where !item.hasTitleStrip:
                // No room for a title: a block with a light tab on top marks it as a folder; a light
                // body needs a line under the tab for the tab to read.
                let tab = Self.snap(min(Self.tabHeight * zoomScale, rect.height / 3), scale)
                context.fill(shape, with: dark ? Self.bands(rect, (tone.tab, tab), body: tone.bodyTop, tone.bodyBottom)
                    : Self.bands(rect, (tone.tab, tab), (tone.edge, 1), body: tone.bodyTop, tone.bodyBottom))
                if rect.height > 14 {
                    makeupBar(item.node, in: CGRect(x: rect.minX + 4, y: rect.maxY - Self.barHeight - 4,
                                                    width: rect.width - 8, height: Self.barHeight),
                              colors: categoryColors, context)
                }

            case .openFolder, .closedFolder:
                let open = item.kind == .openFolder
                context.fill(shape, with: Self.bands(rect, (tone.stripSheen, 1), (tone.strip, stripHeight - 1),
                                                     body: open ? frameShade : tone.bodyTop, open ? frameShade : tone.bodyBottom))
                if !open && rect.height > stripHeight + 14 {
                    makeupBar(item.node, in: CGRect(x: rect.minX + 7, y: rect.minY + stripHeight + 5,
                                                    width: min(rect.width - 14, 160), height: Self.barHeight),
                              colors: categoryColors, context)
                }
                if labeled && rect.width >= 40 {
                    let title = Text(verbatim: "\(open ? "▾" : "▸") \(item.node.name) ").fontWeight(.semibold)
                    let detail = Text(verbatim: "· \(ByteFormatter.string(from: item.node.size(for: sizeMetric)))")
                        .foregroundStyle(titleColor.opacity(0.6))
                    let text = (title + detail).font(.system(size: 11)).foregroundStyle(titleColor)
                    titles.append((context.resolve(text), CGRect(x: rect.minX + 6, y: rect.minY + (stripHeight - 14) / 2,
                                                                 width: rect.width - 12, height: 14)))
                }
            }
            if let outlines {
                context.stroke(Self.outline(of: item, in: rect, inset: 0.5), with: .color(outlines), lineWidth: 1)
            }
        }

        if fading { context.opacity = 1 }
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

    /// Where `item` lands on screen, its edges on whole device pixels so every gap is exact.
    static func screenRect(of item: TreemapItem, zoomScale: CGFloat, panOffset: CGPoint, scale: CGFloat) -> CGRect {
        let minX = snap(panOffset.x + item.rect.x * zoomScale, scale)
        let minY = snap(panOffset.y + item.rect.y * zoomScale, scale)
        return CGRect(x: minX, y: minY,
                      width: snap(panOffset.x + (item.rect.x + item.rect.width) * zoomScale, scale) - minX,
                      height: snap(panOffset.y + (item.rect.y + item.rect.height) * zoomScale, scale) - minY)
    }

    /// The item's continuous rounded shape at `rect`, or `inset` inside it, for the item and the
    /// overlays that trace it. Never rounder than a quarter of the shorter side.
    static func outline(of item: TreemapItem, in rect: CGRect, inset: CGFloat = 0) -> Path {
        let radius = min(item.hasTitleStrip ? frameRadius : blockRadius, min(rect.width, rect.height) / 4)
        return Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: max(0, radius - inset), style: .continuous)
    }

    private static func snap(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Top to bottom: each band a solid color `height` points tall with hard stops, then the body
    /// fading from `top` to `bottom`.
    private static func bands(_ rect: CGRect, _ bands: (Color, CGFloat)..., body top: Color, _ bottom: Color)
        -> GraphicsContext.Shading {
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(bands.count * 2 + 2)
        var y: CGFloat = 0
        for (color, height) in bands {
            stops.append(.init(color: color, location: min(1, y / rect.height)))
            y += max(0, height) // never backwards, so the stops stay in order
            stops.append(.init(color: color, location: min(1, y / rect.height)))
        }
        stops.append(.init(color: top, location: min(1, y / rect.height)))
        stops.append(.init(color: bottom, location: 1))
        return .linearGradient(Gradient(stops: stops),
                               startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.minX, y: rect.maxY))
    }
}

/// The shades drawn from one base color, resolved once per draw. A sheen is the top shade with
/// low-opacity white over it.
private struct Tone {
    let tileSheen: Color, tileTop: Color, tileBottom: Color
    let bodySheen: Color, bodyTop: Color, bodyBottom: Color
    let stripSheen: Color, strip: Color, edge: Color, tab: Color

    init(_ color: Color, dark: Bool, in environment: EnvironmentValues) {
        let base = color.resolve(in: environment)
        func scaled(_ f: Float) -> Color.Resolved {
            Color.Resolved(red: min(1, base.red * f), green: min(1, base.green * f), blue: min(1, base.blue * f))
        }
        func lighter(_ c: Color.Resolved, _ t: Float) -> Color.Resolved {
            Color.Resolved(red: c.red + (1 - c.red) * t, green: c.green + (1 - c.green) * t, blue: c.blue + (1 - c.blue) * t)
        }
        let sheen: Float = dark ? 0.14 : 0.3
        let tileTop = lighter(base, 0.12), bodyTop = dark ? scaled(0.8) : lighter(base, 0.3)
        let strip = dark ? scaled(0.5) : lighter(base, 0.5)
        tileSheen = Color(lighter(tileTop, sheen)); self.tileTop = Color(tileTop)
        tileBottom = Color(dark ? scaled(0.92) : base)
        bodySheen = Color(lighter(bodyTop, sheen)); self.bodyTop = Color(bodyTop)
        bodyBottom = Color(dark ? scaled(0.66) : lighter(base, 0.2))
        stripSheen = Color(lighter(strip, sheen)); self.strip = Color(strip)
        edge = Color(scaled(0.85)) // light mode's line under a tab
        tab = Color(lighter(base, dark ? 0.4 : 0.9))
    }
}
