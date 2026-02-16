import SwiftUI

struct TreemapRenderer {
    let items: [TreemapItem]
    let hoveredItemID: Int?
    let selectedItemID: Int?

    func draw(in context: inout GraphicsContext, size: CGSize) {
        for item in items {
            let rect = CGRect(
                x: item.rect.x,
                y: item.rect.y,
                width: item.rect.width,
                height: item.rect.height
            )

            // Fill
            let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1)
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
                    Path(rect.insetBy(dx: 1, dy: 1)),
                    with: .color(.white),
                    lineWidth: 2
                )
            }

            // Label
            if item.rect.width > 60 && item.rect.height > 16 {
                let labelRect = CGRect(
                    x: item.rect.x + 3,
                    y: item.rect.y + 2,
                    width: item.rect.width - 6,
                    height: min(item.rect.height - 4, 16)
                )
                let text = Text(item.node.name)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                context.draw(text, in: labelRect)
            }

            // Size label for larger rects
            if item.rect.width > 80 && item.rect.height > 32 {
                let sizeRect = CGRect(
                    x: item.rect.x + 3,
                    y: item.rect.y + 16,
                    width: item.rect.width - 6,
                    height: 14
                )
                let sizeText = Text(ByteFormatter.string(from: item.node.ownSize))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
                context.draw(sizeText, in: sizeRect)
            }
        }
    }
}
