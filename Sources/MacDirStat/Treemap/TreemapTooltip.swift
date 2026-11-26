import SwiftUI

/// One line of a folder's makeup in the tooltip; `category == nil` is "Other types".
struct MakeupRow: Equatable {
    let category: FileCategory?
    let fraction: Double
    let size: Int64
}

/// Up to four rows from a largest-first breakdown. With more than four categories, the fourth
/// row sums the rest as "Other types". Rows under 1% of `total` are left out.
func makeupRows(_ breakdown: [(category: FileCategory, size: Int64)], total: Int64) -> [MakeupRow] {
    guard total > 0 else { return [] }
    let folds = breakdown.count > 4
    var rows = breakdown.prefix(folds ? 3 : 4).map {
        MakeupRow(category: $0.category, fraction: Double($0.size) / Double(total), size: $0.size)
    }
    if folds {
        let rest = breakdown[3...].reduce(0) { $0 + $1.size }
        rows.append(MakeupRow(category: nil, fraction: Double(rest) / Double(total), size: rest))
    }
    return rows.filter { $0.fraction >= 0.01 }
}

/// The pointer over the treemap. Only the tooltip reads its location, so following the
/// cursor redraws the tooltip and nothing else.
@MainActor @Observable final class TreemapCursor {
    var location: CGPoint = .zero
    /// What the last single click hit, for the double click that may follow. Weak, so it
    /// doesn't keep a replaced tree alive.
    @ObservationIgnored weak var clickedNode: FileNode?
}

/// The tooltip beside the cursor, flipped to the other side at the edges. Never hit-testable, so
/// hover and clicks reach the treemap. Following the cursor only offsets the drawn tooltip, so a
/// move lays nothing out again.
struct TreemapTooltipLayer: View {
    let cursor: TreemapCursor
    let item: TreemapItem
    let root: FileNode
    let sizeMetric: SizeMetric
    nonisolated private static let gap: CGFloat = 14, margin: CGFloat = 8

    var body: some View {
        TreemapTooltip(item: item, root: root, sizeMetric: sizeMetric)
            .visualEffect { [cursor = cursor.location] content, proxy in
                // The layer's bounds in the tooltip's coordinates, whose origin sits at the margin.
                let bounds = proxy.bounds(of: .named("tooltipLayer")) ?? .zero, size = proxy.size
                var x = cursor.x + Self.gap, y = cursor.y + Self.gap
                if x + size.width > bounds.width - Self.margin { x = cursor.x - Self.gap - size.width }
                if y + size.height > bounds.height - Self.margin { y = cursor.y - Self.gap - size.height }
                return content.offset(x: bounds.minX + max(Self.margin, x), y: bounds.minY + max(Self.margin, y))
            }
            .frame(maxWidth: 360, alignment: .leading)
            .padding(Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(.named("tooltipLayer"))
            .allowsHitTesting(false)
    }
}

/// Name, size and file count, the path from the shown folder, and a folder's makeup by category.
private struct TreemapTooltip: View {
    let item: TreemapItem
    let root: FileNode
    let sizeMetric: SizeMetric
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let node = item.node
            let path = relativePath(node)
            if case .smallerItems(let count, let size) = item.kind {
                // The node is the folder that holds them, so the path says where they are.
                Text(verbatim: "\(count.formatted()) smaller items · \(ByteFormatter.string(from: size))")
                    .font(.system(size: 13, weight: .semibold))
                pathText(path)
            } else {
                Text(verbatim: node.name).font(.system(size: 13, weight: .semibold))
                Text(verbatim: summary(node))
                pathText(path)
                if node.isDirectory { makeup(node.categoryBreakdown(metric: sizeMetric)) }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial),
                    in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    @ViewBuilder
    private func pathText(_ path: String) -> some View {
        if !path.isEmpty {
            Text(verbatim: path).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
        }
    }

    private func summary(_ node: FileNode) -> String {
        let size = ByteFormatter.string(from: node.size(for: sizeMetric))
        guard node.isDirectory else { return size }
        let files = node.fileCount == 1 ? "1 file" : "\(node.fileCount.formatted()) files"
        return "\(size) · \(files)"
    }

    /// From the shown folder down to the node, which the shown folder doesn't repeat.
    private func relativePath(_ node: FileNode) -> String {
        var names: [String] = []
        var current: FileNode? = node
        while let folder = current, folder !== root {
            names.append(folder.name)
            current = folder.parent
        }
        return names.reversed().joined(separator: " › ")
    }

    /// The category bar over the rows, as wide as the rows.
    @ViewBuilder
    private func makeup(_ breakdown: [(category: FileCategory, size: Int64)]) -> some View {
        let total = breakdown.reduce(0) { $0 + $1.size }
        let rows = makeupRows(breakdown, total: total)
        if !rows.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 1) {
                GridRow {
                    Canvas { context, size in
                        context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
                        var x: CGFloat = 0
                        for segment in breakdown {
                            let width = size.width * CGFloat(segment.size) / CGFloat(total)
                            context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                                         with: .color(segment.category.color))
                            x += width
                        }
                    }
                    .frame(height: 5)
                    .padding(.vertical, 4)
                    .gridCellColumns(4)
                    .gridCellUnsizedAxes(.horizontal)
                }
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    GridRow {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(row.category?.color ?? Color.gray.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(verbatim: row.category?.displayName ?? "Other types")
                        Text(row.fraction, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(verbatim: ByteFormatter.string(from: row.size))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .padding(.top, 2)
        }
    }
}
