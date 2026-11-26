import SwiftUI

/// The selected item's rounded shape in layout points, and how much the rest of the view is dimmed.
struct SelectionShape {
    var rect: TreemapRect
    var radius: Double
    /// 1 for a folder, whose outside is dimmed; 0 for a file.
    var dim: Double

    init(rect: TreemapRect, radius: Double, dim: Double) {
        self.rect = rect
        self.radius = radius
        self.dim = dim
    }

    /// `item`'s shape: its rect, and the corner radius it is drawn with at `zoomScale`.
    init(_ item: TreemapItem, dims: Bool, zoomScale: CGFloat) {
        let size = CGSize(width: item.rect.width * zoomScale, height: item.rect.height * zoomScale)
        self.init(rect: item.rect, radius: TreemapRenderer.cornerRadius(of: item, size: size) / zoomScale, dim: dims ? 1 : 0)
    }

    func interpolated(to end: SelectionShape, _ t: Double) -> SelectionShape {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return SelectionShape(rect: TreemapRect(x: mix(rect.x, end.rect.x), y: mix(rect.y, end.rect.y),
                                                width: mix(rect.width, end.rect.width),
                                                height: mix(rect.height, end.rect.height)),
                              radius: mix(radius, end.radius), dim: mix(dim, end.dim))
    }
}

/// The selection, built on main's: a selected folder dims everything outside it. The cut-out
/// follows the item's rounded shape, and an accent ring with a soft shadow lifts the item above
/// its neighbours. When the selection moves within one layout, ring and cut-out travel to the new item.
struct TreemapSelectionOverlay: View, Equatable {
    /// The selected item in the layout of `generation`. `dims` for a selected folder.
    struct Selection: Equatable {
        let generation: Int
        let id: Int
        let dims: Bool
    }

    /// Critically damped, like a spring with no bounce: quick to start, settled after `duration`.
    nonisolated static let response = 0.28, duration = 0.36

    nonisolated static func progress(elapsed: Double) -> Double {
        guard elapsed < duration else { return 1 }
        let w = 2 * Double.pi / response * max(0, elapsed)
        return 1 - (1 + w) * exp(-w)
    }

    let items: [TreemapItem]
    let selection: Selection?
    let zoomScale: CGFloat
    let panOffset: CGPoint
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the selection travels from, and when it left; nil when it sits still.
    @State private var travel: (from: SelectionShape, start: Date)?

    /// Hover re-runs the treemap's body; the selection redraws only when it, the layout or zoom changes.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && lhs.zoomScale == rhs.zoomScale && lhs.panOffset == rhs.panOffset
    }

    var body: some View {
        Group {
            if let travel {
                // In the tree only while the selection moves, so a still one gets no ticks.
                TimelineView(.animation) { timeline in
                    canvas(travel.from, Self.progress(elapsed: timeline.date.timeIntervalSince(travel.start)))
                }
                .task(id: travel.start) {
                    try? await Task.sleep(for: .seconds(Self.duration))
                    if !Task.isCancelled { self.travel = nil }
                }
            } else {
                canvas(nil, 1)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: selection) { old, new in
            // Travels only between two items of one layout; a new layout has its own transition.
            guard !reduceMotion, let old, let new, old.generation == new.generation,
                  let from = shape(of: old), shape(of: new) != nil else {
                travel = nil
                return
            }
            let now = Date()
            // Interrupted mid-way, it leaves from where it is.
            let start = travel.map { $0.from.interpolated(to: from, Self.progress(elapsed: now.timeIntervalSince($0.start))) }
            travel = (start ?? from, now)
        }
    }

    private func shape(of selection: Selection) -> SelectionShape? {
        guard items.indices.contains(selection.id) else { return nil }
        return SelectionShape(items[selection.id], dims: selection.dims, zoomScale: zoomScale)
    }

    private func canvas(_ from: SelectionShape?, _ progress: Double) -> some View {
        Canvas { context, size in
            guard let selection, let target = shape(of: selection) else { return }
            let shape = from?.interpolated(to: target, progress) ?? target
            // Edges snapped like the item's, so a still ring sits exactly on it.
            let scale = context.environment.displayScale
            func snap(_ v: Double) -> CGFloat { TreemapRenderer.snap(v, scale) }
            let r = shape.rect
            let minX = snap(panOffset.x + r.x * zoomScale), minY = snap(panOffset.y + r.y * zoomScale)
            let rect = CGRect(x: minX, y: minY, width: snap(panOffset.x + (r.x + r.width) * zoomScale) - minX,
                              height: snap(panOffset.y + (r.y + r.height) * zoomScale) - minY)
            Self.draw(rect, radius: shape.radius * zoomScale, dim: shape.dim, contrast: contrast, in: &context, size: size)
        }
    }

    /// Scrim outside a folder, shadow outside the item, then the ring inside its edge.
    static func draw(_ rect: CGRect, radius: CGFloat, dim: Double, contrast: ColorSchemeContrast,
                     in context: inout GraphicsContext, size: CGSize) {
        let viewport = CGRect(origin: .zero, size: size)
        guard rect.intersects(viewport) else { return }
        let dark = context.environment.colorScheme == .dark
        let shape = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        var outside = Path(viewport)
        outside.addPath(shape)
        if dim > 0 {
            // Softer than main's 0.55: the ring marks the folder, the scrim only sets the rest back.
            // Dark mode's colors are already dim, so it takes more to set them back.
            context.fill(outside, with: .color(.black.opacity((dark ? 0.45 : 0.3) * dim)), style: FillStyle(eoFill: true))
        }
        if contrast != .increased {
            // The item's own fill, clipped away, leaves only its shadow on the neighbours. A black
            // shadow is lost on a dark treemap, so there it glows in the accent color.
            context.drawLayer { layer in
                layer.clip(to: outside, style: FillStyle(eoFill: true))
                layer.addFilter(.shadow(color: dark ? .accentColor.opacity(0.6) : .black.opacity(0.35), radius: 6, y: dark ? 0 : 2))
                layer.fill(shape, with: .color(.black))
            }
        }
        let ring = 2.5
        context.stroke(Path(roundedRect: rect.insetBy(dx: ring / 2, dy: ring / 2), cornerRadius: max(0, radius - ring / 2),
                            style: .continuous),
                       with: .color(.accentColor), lineWidth: ring)
    }
}
