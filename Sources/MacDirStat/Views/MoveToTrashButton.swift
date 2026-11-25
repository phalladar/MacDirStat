import SwiftUI

/// Move to Trash for the sidebar and treemap menus. When the item can't or shouldn't be
/// trashed casually, the reason shows as the menu item's subtitle.
struct MoveToTrashButton: View {
    let node: FileNode
    let isBusy: Bool
    let action: (FileNode) -> Void

    var body: some View {
        Button {
            action(node)
        } label: {
            // Label then Text: the menu shows the Label's icon and the Text as subtitle.
            // A Label holding both Texts drops the subtitle.
            Label("Move to Trash…", systemImage: "trash")
            if node.hasCloudOnlyContent {
                Text(node.isDirectory ? "Contains items stored in iCloud" : "Stored in iCloud")
            } else if node.hasUnscannedFolders {
                Text("Contains folders that weren't scanned")
            } else if isSyncedWithICloud {
                Text("Also deletes it from iCloud")
            }
        }
        .disabled(isBusy || node.hasCloudOnlyContent || node.hasUnscannedFolders)
    }

    /// Trashing a synced item removes it from iCloud on every device, not just this Mac.
    private var isSyncedWithICloud: Bool {
        let values = try? withoutDatalessMaterialization {
            try URL(fileURLWithPath: node.path).resourceValues(forKeys: [.isUbiquitousItemKey])
        }
        return values?.isUbiquitousItem == true
    }
}
