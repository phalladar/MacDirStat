import SwiftUI

struct TreemapRenderer {
    let items: [TreemapItem]
    let hoveredItemID: Int?
    let selectedItemID: Int?
    let zoomScale: CGFloat
    let panOffset: CGPoint
    let showLabels: Bool
    let sizeMetric: SizeMetric

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let viewport = CGRect(origin: .zero, size: size)

        for item in items {
            // Transform layout coordinates to screen coordinates
            let screenRect = CGRect(
                x: panOffset.x + item.rect.x * zoomScale,
                y: panOffset.y + item.rect.y * zoomScale,
                width: item.rect.width * zoomScale,
                height: item.rect.height * zoomScale
            )

            // Viewport culling — skip items entirely off-screen
            guard screenRect.intersects(viewport) else { continue }

            // Fill
            let path = Path(roundedRect: screenRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1)
            context.fill(path, with: .color(Color(cgColor: item.color)))

            // Border
            context.stroke(path, with: .color(.black.opacity(0.3)), lineWidth: 0.5)

            // Hover highlight
            if item.id == hoveredItemID {
                context.fill(path, with: .color(.white.opacity(0.25)))
            }

            // Selection highlight
            if item.id == selectedItemID {
                context.stroke(
                    Path(screenRect.insetBy(dx: 1, dy: 1)),
                    with: .color(.white),
                    lineWidth: 2
                )
            }

            // Name label — font stays at 10pt regardless of zoom
            // Labels are suppressed during active zoom/pan for smooth rendering
            if showLabels && screenRect.width > 60 && screenRect.height > 16 {
                let labelRect = CGRect(
                    x: screenRect.minX + 3,
                    y: screenRect.minY + 2,
                    width: screenRect.width - 6,
                    height: min(screenRect.height - 4, 16)
                )
                let text = Text(item.node.name)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                context.draw(text, in: labelRect)
            }

            // Size label for larger rects
            if showLabels && screenRect.width > 80 && screenRect.height > 32 {
                let sizeRect = CGRect(
                    x: screenRect.minX + 3,
                    y: screenRect.minY + 16,
                    width: screenRect.width - 6,
                    height: 14
                )
                let sizeText = Text(ByteFormatter.string(from: item.node.size(for: sizeMetric)))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
                context.draw(sizeText, in: sizeRect)
            }
        }
    }
}
