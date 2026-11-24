import SwiftUI

struct SizeSparkline: View {
    let segments: [(category: FileCategory, size: Int64)]
    let fractionOfParent: Double

    var body: some View {
        Canvas { context, size in
            let track = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: track, cornerRadius: size.height / 2), with: .style(.quaternary))

            let total = segments.reduce(0) { $0 + $1.size }
            guard total > 0, fractionOfParent > 0 else { return }
            let fill = CGRect(x: 0, y: 0, width: max(1, size.width * fractionOfParent), height: size.height)
            context.clip(to: Path(roundedRect: fill, cornerRadius: size.height / 2))
            var x: CGFloat = 0
            for segment in segments {
                let width = fill.width * CGFloat(segment.size) / CGFloat(total)
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                             with: .color(segment.category.color))
                x += width
            }
        }
        .frame(width: 44, height: 6)
        .accessibilityLabel("\(Int((fractionOfParent * 100).rounded()))% of parent folder")
    }
}
